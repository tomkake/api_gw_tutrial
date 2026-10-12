package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"github.com/aws/aws-lambda-go/events"
	"google.golang.org/api/idtoken"
	"google.golang.org/api/option"
	"io"
	"math/big"
	"net/http"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func signedFixture(t *testing.T) (authorizer, func(map[string]any) string) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	b64 := base64.RawURLEncoding.EncodeToString
	jwks, _ := json.Marshal(map[string]any{"keys": []map[string]string{{"kty": "RSA", "kid": "fixture-key", "alg": "RS256", "use": "sig", "n": b64(key.N.Bytes()), "e": b64(big.NewInt(int64(key.E)).Bytes())}}})
	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.String() != "https://www.googleapis.com/oauth2/v3/certs" {
			t.Fatalf("unexpected key source: %s", req.URL)
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Cache-Control": {"public, max-age=3600"}}, Body: io.NopCloser(strings.NewReader(string(jwks)))}, nil
	})}
	validator, err := idtoken.NewValidator(context.Background(), option.WithHTTPClient(client))
	if err != nil {
		t.Fatal(err)
	}
	sign := func(claims map[string]any) string {
		payload, _ := json.Marshal(claims)
		input := b64([]byte(`{"alg":"RS256","kid":"fixture-key","typ":"JWT"}`)) + "." + b64(payload)
		digest := sha256.Sum256([]byte(input))
		sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		return input + "." + b64(sig)
	}
	return authorizer{validate: validator.Validate}, sign
}
func validClaims() map[string]any {
	return map[string]any{"iss": "https://accounts.google.com", "aud": "test-client", "sub": "example-user", "email": "allowed@example.invalid", "email_verified": true, "iat": time.Now().Unix() - 5, "exp": time.Now().Unix() + 3600}
}
func authEvent(token, route string) events.APIGatewayV2CustomAuthorizerV2Request {
	return events.APIGatewayV2CustomAuthorizerV2Request{Type: "REQUEST", Version: "2.0", RouteKey: route, Headers: map[string]string{"authorization": "Bearer " + token}}
}
func TestGoogleTokenAuthorization(t *testing.T) {
	t.Setenv("GOOGLE_CLIENT_ID", "test-client")
	t.Setenv("ALLOWED_EMAIL", "allowed@example.invalid")
	a, sign := signedFixture(t)
	for _, route := range []string{"GET /private", "GET /secondary"} {
		response, err := a.handle(context.Background(), authEvent(sign(validClaims()), route))
		if err != nil || !response.IsAuthorized {
			t.Fatalf("valid token denied: %v", err)
		}
		if len(response.Context) != 1 || response.Context["authorized"] != true {
			t.Fatal("only the authorization decision may be passed to integrations")
		}
	}
	cases := []struct {
		name, claim string
		value       any
	}{
		{"wrong audience", "aud", "other-client"}, {"wrong issuer", "iss", "https://example.invalid"},
		{"expired", "exp", time.Now().Unix() - 1}, {"future issue time", "iat", time.Now().Unix() + 3600},
		{"future not-before", "nbf", time.Now().Unix() + 3600}, {"missing subject", "sub", ""},
		{"other email", "email", "other@example.invalid"}, {"missing email", "email", nil},
		{"unverified email", "email_verified", false}, {"wrong verification type", "email_verified", "true"}, {"missing verification", "email_verified", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			claims := validClaims()
			claims[c.claim] = c.value
			response, err := a.handle(context.Background(), authEvent(sign(claims), "GET /secondary"))
			if err != nil || response.IsAuthorized {
				t.Fatalf("invalid token allowed: %v", err)
			}
		})
	}
	token := sign(validClaims())
	parts := strings.Split(token, ".")
	if parts[2][0] == 'A' {
		parts[2] = "B" + parts[2][1:]
	} else {
		parts[2] = "A" + parts[2][1:]
	}
	for _, bad := range []string{"not-a-jwt", strings.Join(parts, ".")} {
		response, err := a.handle(context.Background(), authEvent(bad, "GET /secondary"))
		if err != nil || response.IsAuthorized {
			t.Fatal("invalid signature/token allowed")
		}
	}
	_, attackerSign := signedFixture(t)
	response, err := a.handle(context.Background(), authEvent(attackerSign(validClaims()), "GET /secondary"))
	if err != nil || response.IsAuthorized {
		t.Fatal("untrusted signing key allowed")
	}
}
func TestMissingConfigAndInvalidRequests(t *testing.T) {
	t.Setenv("GOOGLE_CLIENT_ID", "test-client")
	t.Setenv("ALLOWED_EMAIL", "allowed@example.invalid")
	a := authorizer{validate: func(context.Context, string, string) (*idtoken.Payload, error) {
		t.Fatal("invalid request reached verification")
		return nil, nil
	}}
	for _, event := range []events.APIGatewayV2CustomAuthorizerV2Request{{}, authEvent("token", "GET /public"), {Type: "REQUEST", Version: "2.0", RouteKey: "GET /secondary"}} {
		response, err := a.handle(context.Background(), event)
		if err != nil || response.IsAuthorized {
			t.Fatal("invalid request allowed")
		}
	}
	for _, key := range []string{"ALLOWED_EMAIL", "GOOGLE_CLIENT_ID"} {
		t.Run(key, func(t *testing.T) {
			t.Setenv(key, "")
			response, err := a.handle(context.Background(), authEvent("token", "GET /secondary"))
			if err == nil || response.IsAuthorized {
				t.Fatal("missing configuration did not fail closed")
			}
		})
	}
}

func TestDispatchAuthorizerAndPrivateEndpoint(t *testing.T) {
	t.Setenv("GOOGLE_CLIENT_ID", "test-client")
	t.Setenv("ALLOWED_EMAIL", "allowed@example.invalid")
	a, sign := signedFixture(t)
	raw, _ := json.Marshal(authEvent(sign(validClaims()), "GET /private"))
	result, err := a.dispatch(context.Background(), raw)
	if err != nil {
		t.Fatal(err)
	}
	decision, ok := result.(events.APIGatewayV2CustomAuthorizerSimpleResponse)
	if !ok || !decision.IsAuthorized {
		t.Fatal("authorizer dispatch failed")
	}
	event := events.APIGatewayV2HTTPRequest{Version: "2.0", RouteKey: "GET /private",
		RequestContext: events.APIGatewayV2HTTPRequestContext{RequestID: "example-request",
			Authorizer: &events.APIGatewayV2HTTPRequestContextAuthorizerDescription{Lambda: decision.Context}}}
	raw, _ = json.Marshal(event)
	result, err = a.dispatch(context.Background(), raw)
	response, ok := result.(events.APIGatewayV2HTTPResponse)
	if err != nil || !ok || response.StatusCode != 200 {
		t.Fatalf("endpoint dispatch failed: %v", err)
	}
	var body map[string]string
	if err := json.Unmarshal([]byte(response.Body), &body); err != nil {
		t.Fatal(err)
	}
	if len(body) != 2 || body["message"] != "Hello from the first Lambda!" || body["request_id"] != "example-request" {
		t.Fatal("unexpected first Lambda business response")
	}
	for _, auth := range []*events.APIGatewayV2HTTPRequestContextAuthorizerDescription{nil, {Lambda: map[string]interface{}{"authorized": false}}} {
		event.RequestContext.Authorizer = auth
		response, err := businessHandler(event)
		if err != nil || response.StatusCode != 403 {
			t.Fatal("endpoint accepted missing/denied authorizer decision")
		}
	}
	event.RouteKey = "GET /secondary"
	response, err = businessHandler(event)
	if err != nil || response.StatusCode != 404 {
		t.Fatal("first business handler accepted second Lambda route")
	}
}
