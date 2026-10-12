package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"google.golang.org/api/idtoken"
)

type authorizer struct {
	validate func(context.Context, string, string) (*idtoken.Payload, error)
}

func (a authorizer) handle(ctx context.Context, event events.APIGatewayV2CustomAuthorizerV2Request) (response events.APIGatewayV2CustomAuthorizerSimpleResponse, err error) {
	// Log the decision, never the token, headers, email, or decoded claims.
	defer func() {
		record, _ := json.Marshal(map[string]any{
			"requestId": event.RequestContext.RequestID, "routeKey": event.RouteKey,
			"authorized": response.IsAuthorized, "kind": "authorization",
		})
		fmt.Println(string(record))
	}()
	clientID, allowedEmail := os.Getenv("GOOGLE_CLIENT_ID"), os.Getenv("ALLOWED_EMAIL")
	if clientID == "" || allowedEmail == "" {
		return response, errors.New("authorizer configuration missing")
	}
	if event.Type != "REQUEST" || event.Version != "2.0" || (event.RouteKey != "GET /private" && event.RouteKey != "GET /secondary") {
		return response, nil
	}
	var header string
	for key, value := range event.Headers {
		if strings.EqualFold(key, "authorization") {
			header = value
		}
	}
	parts := strings.Fields(header)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return response, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// Google's library verifies the signature against Google's cached public keys,
	// audience, and expiry. Check the remaining identity/authorization claims here.
	payload, validateErr := a.validate(ctx, parts[1], clientID)
	if validateErr != nil || payload == nil {
		return response, nil
	}
	now := time.Now().Unix()
	if payload.Issuer != "https://accounts.google.com" || payload.Audience != clientID || payload.Subject == "" ||
		payload.IssuedAt <= 0 || payload.IssuedAt > now || payload.Expires <= now {
		return response, nil
	}
	if nbf, exists := payload.Claims["nbf"]; exists {
		value, ok := nbf.(float64)
		if !ok || value > float64(now) {
			return response, nil
		}
	}
	email, emailOK := payload.Claims["email"].(string)
	verified, verifiedOK := payload.Claims["email_verified"].(bool)
	response.IsAuthorized = emailOK && email == allowedEmail && verifiedOK && verified
	if response.IsAuthorized {
		response.Context = map[string]interface{}{"authorized": true}
	}
	return response, nil
}

// API Gateway invokes this function in two roles: authorizer and /private integration.
func (a authorizer) dispatch(ctx context.Context, raw json.RawMessage) (any, error) {
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, err
	}
	if envelope.Type == "REQUEST" {
		var event events.APIGatewayV2CustomAuthorizerV2Request
		if err := json.Unmarshal(raw, &event); err != nil {
			return nil, err
		}
		return a.handle(ctx, event)
	}
	if envelope.Type != "" {
		return nil, errors.New("unsupported event type")
	}
	var event events.APIGatewayV2HTTPRequest
	if err := json.Unmarshal(raw, &event); err != nil {
		return nil, err
	}
	return businessHandler(event)
}

func businessHandler(event events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	record, _ := json.Marshal(map[string]string{"requestId": event.RequestContext.RequestID, "routeKey": event.RouteKey, "kind": "business"})
	fmt.Println(string(record))
	status := 200
	body := map[string]string{"message": "Hello from the first Lambda!", "request_id": event.RequestContext.RequestID}
	switch {
	case event.Version != "2.0" || event.RouteKey != "GET /private":
		status = 404
		body = map[string]string{"message": "not found"}
	case event.RequestContext.Authorizer == nil || event.RequestContext.Authorizer.Lambda["authorized"] != true:
		status = 403
		body = map[string]string{"message": "forbidden"}
	}
	encoded, err := json.Marshal(body)
	return events.APIGatewayV2HTTPResponse{StatusCode: status, Headers: map[string]string{"content-type": "application/json", "cache-control": "no-store"}, Body: string(encoded)}, err
}

func main() { lambda.Start((authorizer{validate: idtoken.Validate}).dispatch) }
