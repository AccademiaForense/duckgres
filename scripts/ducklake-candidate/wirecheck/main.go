// wirecheck qualifies a locally built candidate through its PostgreSQL wire endpoint.
package main

import (
	"context"
	"fmt"
	"os"
	"time"
)

func main() {
	if len(os.Args) != 1 {
		fmt.Fprintln(os.Stderr, "wirecheck accepts only DUCKGRES_BUNDLE_TEST_* environment inputs, no DSN or arguments")
		os.Exit(1)
	}
	cfg, err := configFromEnv(os.Environ())
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		err = qualify(ctx, cfg)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "FAIL: binary COPY wire qualification:", err)
		os.Exit(1)
	}
	fmt.Println("PASS: binary COPY (3 rows), targeted S3 flush, new-connection reread, owned-fixture cleanup")
}
