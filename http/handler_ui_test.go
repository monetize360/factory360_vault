// Copyright IBM Corp. 2016, 2025
// SPDX-License-Identifier: BUSL-1.1

package http

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"testing/fstest"
)

// TestHandleUI_NonceInjection verifies that HTML served through handleUI has
// the CSP nonce injected and arrives complete. http.FileServer sets
// Content-Length from the file on disk, so the longer, rewritten body must not
// be sent with that stale length or clients receive a truncated page.
func TestHandleUI_NonceInjection(t *testing.T) {
	const index = "<!DOCTYPE html>\n<html>\n<head>\n<title>Vault</title>\n</head>\n<body></body>\n</html>\n"
	const nonce = "test-nonce"

	files := fstest.MapFS{"index.html": {Data: []byte(index)}}
	ui := handleUI(http.FileServer(http.FS(files)))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := context.WithValue(r.Context(), cspNonceContextKey{}, nonce)
		ui.ServeHTTP(w, r.WithContext(ctx))
	}))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("reading body: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if !strings.Contains(string(body), `<meta name="csp-nonce" content="`+nonce+`">`) {
		t.Fatalf("nonce meta tag not injected; body:\n%s", body)
	}
	if !strings.Contains(string(body), "</html>") {
		t.Fatalf("body truncated:\n%s", body)
	}
	if cl := resp.Header.Get("Content-Length"); cl != "" && cl != strconv.Itoa(len(body)) {
		t.Fatalf("Content-Length = %s, but body is %d bytes", cl, len(body))
	}
}
