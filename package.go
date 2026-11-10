package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

const packageVersion = "10.4.0.0p1-Preview"
const packageURL = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.4.0.0p1-Preview/OpenSSH-Win64-v10.4.0.0.msi"
const packageSHA256 = "788d8643464a01eb63640a2fd746f9ed23d106b5a901a35f88dc8cd40e446ac9"

func checkedPackage(data []byte, expected string) error {
	if got := fmt.Sprintf("%x", sha256.Sum256(data)); got != expected {
		return fmt.Errorf("安装包 SHA256 不符：%s", got)
	}
	return nil
}

func fetchPackage(ctx context.Context, url, expected, cache string) ([]byte, error) {
	if data, err := os.ReadFile(cache); err == nil && checkedPackage(data, expected) == nil {
		return data, nil
	}
	client := &http.Client{Timeout: 5 * time.Minute, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Scheme != "https" || len(via) >= 10 {
			return fmt.Errorf("拒绝不安全或过多的下载重定向")
		}
		return nil
	}}
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("下载失败：HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (64<<20)+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 64<<20 {
		return nil, fmt.Errorf("安装包超过 64 MiB")
	}
	if err := checkedPackage(data, expected); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(cache), 0700); err != nil {
		return nil, err
	}
	tmp, err := os.CreateTemp(filepath.Dir(cache), ".download-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp.Name())
	if _, err = tmp.Write(data); err != nil {
		tmp.Close()
		return nil, err
	}
	if err = tmp.Close(); err != nil {
		return nil, err
	}
	if err = os.Rename(tmp.Name(), cache); err != nil {
		return nil, err
	}
	return data, nil
}
