package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestPackageCacheValidation(t *testing.T) {
	data := []byte("known installer")
	hash := fmt.Sprintf("%x", sha256.Sum256(data))
	if checkedPackage(data, hash) != nil {
		t.Fatal("valid package rejected")
	}
	if checkedPackage([]byte("tampered"), hash) == nil {
		t.Fatal("modified package accepted")
	}
	cache := filepath.Join(t.TempDir(), "installer.msi")
	if err := os.WriteFile(cache, data, 0600); err != nil {
		t.Fatal(err)
	}
	got, err := fetchPackage(context.Background(), "https://invalid.invalid/file", hash, cache)
	if err != nil || string(got) != string(data) {
		t.Fatal("valid cache was not reused", err)
	}
}
