package main

import (
	"context"
	"encoding/json"
	"github.com/aws/aws-lambda-go/events"
	"testing"
)

func TestBusinessHandlerWithoutAuthenticationKnowledge(t *testing.T) {
	// No token, identity claims, authorizer context, or email configuration needed.
	for _, route := range []string{"GET /secondary"} {
		event := events.APIGatewayV2HTTPRequest{Version: "2.0", RouteKey: route, RequestContext: events.APIGatewayV2HTTPRequestContext{RequestID: "example-request"}}
		response, err := handler(context.Background(), event)
		if err != nil || response.StatusCode != 200 {
			t.Fatalf("business response: %d %v", response.StatusCode, err)
		}
		var body map[string]string
		if err := json.Unmarshal([]byte(response.Body), &body); err != nil {
			t.Fatal(err)
		}
		if len(body) != 2 || body["message"] != "Hello from the second Lambda!" || body["request_id"] != "example-request" {
			t.Fatalf("unexpected response: %s", response.Body)
		}
	}
	response, err := handler(context.Background(), events.APIGatewayV2HTTPRequest{RouteKey: "GET /private"})
	if err != nil || response.StatusCode != 404 {
		t.Fatal("unknown route must be 404")
	}
}
