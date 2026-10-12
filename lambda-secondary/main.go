package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
)

// Authentication and authorization run upstream. This handler only does business work.
func handler(_ context.Context, event events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	record, _ := json.Marshal(map[string]string{"requestId": event.RequestContext.RequestID, "routeKey": event.RouteKey, "kind": "business"})
	fmt.Println(string(record))
	status := 200
	body := map[string]string{"message": "Hello from the second Lambda!", "request_id": event.RequestContext.RequestID}
	if event.RouteKey != "GET /secondary" {
		status = 404
		body = map[string]string{"message": "not found"}
	}
	encoded, err := json.Marshal(body)
	return events.APIGatewayV2HTTPResponse{
		StatusCode: status,
		Headers:    map[string]string{"content-type": "application/json", "cache-control": "no-store"},
		Body:       string(encoded),
	}, err
}

func main() { lambda.Start(handler) }
