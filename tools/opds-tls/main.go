// HomeLibre HTTPS transport for a private, loopback OPDS server.
package main

import (
	"bufio"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type configuration struct {
	ListenPort  int    `json:"listen_port"`
	BackendPort int    `json:"backend_port"`
	AllowLAN    bool   `json:"allow_lan"`
	Route       string `json:"route"`
	Hostname    string `json:"hostname"`
	Certificate string `json:"certificate"`
	PrivateKey  string `json:"private_key"`
}

var catalogRoute = regexp.MustCompile(`^/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/opds$`)

func readConfig(input *bufio.Reader) (configuration, error) {
	var config configuration
	line, err := input.ReadSlice('\n')
	if err != nil || json.Unmarshal(line, &config) != nil {
		return config, errors.New("invalid configuration")
	}
	if config.ListenPort < 1024 || config.ListenPort > 65535 ||
		config.BackendPort < 1024 || config.BackendPort > 65535 ||
		config.ListenPort == config.BackendPort || !catalogRoute.MatchString(config.Route) ||
		config.Hostname == "" || !filepath.IsAbs(config.Certificate) || !filepath.IsAbs(config.PrivateKey) {
		return config, errors.New("invalid configuration")
	}
	return config, nil
}

func readPEM(name string) ([]byte, error) {
	file, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	const limit = 1 << 20
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.New("invalid PEM file")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || len(data) > limit {
		return nil, errors.New("invalid PEM file")
	}
	return data, nil
}

func loadCertificate(config configuration) (tls.Certificate, error) {
	certPEM, err := readPEM(config.Certificate)
	if err != nil {
		return tls.Certificate{}, errors.New("certificate could not be read")
	}
	keyPEM, err := readPEM(config.PrivateKey)
	if err != nil {
		return tls.Certificate{}, errors.New("private key could not be read")
	}
	defer clear(keyPEM)
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil || cert.Leaf == nil {
		return tls.Certificate{}, errors.New("invalid or mismatched PEM certificate and key")
	}
	if now := time.Now(); now.Before(cert.Leaf.NotBefore) || now.After(cert.Leaf.NotAfter) {
		return tls.Certificate{}, errors.New("certificate is outside its validity period")
	}
	if cert.Leaf.VerifyHostname(config.Hostname) != nil {
		return tls.Certificate{}, errors.New("certificate does not cover the public hostname")
	}
	return cert, nil
}

func catalogHandler(config configuration) http.Handler {
	target := &url.URL{Scheme: "http", Host: net.JoinHostPort("127.0.0.1", strconv.Itoa(config.BackendPort))}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(request *httputil.ProxyRequest) {
			request.SetURL(target)
			request.Out.Header.Del("Authorization")
			request.Out.Header.Del("Cookie")
			request.Out.Header.Del("X-Forwarded-Prefix")
		},
		Transport: &http.Transport{
			DialContext:           (&net.Dialer{Timeout: 3 * time.Second}).DialContext,
			ResponseHeaderTimeout: 30 * time.Second,
			DisableKeepAlives:     true,
			DisableCompression:    true,
		},
	}
	active := make(chan struct{}, 8)
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Cache-Control", "no-store")
		writer.Header().Set("X-Content-Type-Options", "nosniff")
		if request.URL.Path != config.Route && !strings.HasPrefix(request.URL.Path, config.Route+"/") {
			http.NotFound(writer, request)
			return
		}
		if request.Method != http.MethodGet && request.Method != http.MethodHead {
			writer.Header().Set("Allow", "GET, HEAD")
			writer.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if request.ContentLength != 0 || len(request.TransferEncoding) != 0 {
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		select {
		case active <- struct{}{}:
			defer func() { <-active }()
			proxy.ServeHTTP(writer, request)
		default:
			writer.WriteHeader(http.StatusServiceUnavailable)
		}
	})
}

func serve(input *bufio.Reader, output io.Writer) error {
	config, err := readConfig(input)
	if err != nil {
		return err
	}
	certificate, err := loadCertificate(config)
	if err != nil {
		return err
	}
	host := "127.0.0.1"
	if config.AllowLAN {
		host = "0.0.0.0"
	}
	listener, err := net.Listen("tcp4", net.JoinHostPort(host, strconv.Itoa(config.ListenPort)))
	if err != nil {
		return errors.New("HTTPS port is unavailable")
	}
	defer listener.Close()
	server := &http.Server{
		Handler:           catalogHandler(config),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      5 * time.Minute,
		IdleTimeout:       20 * time.Second,
		MaxHeaderBytes:    16 << 10,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{certificate},
			MinVersion:   tls.VersionTLS12,
		},
	}
	if _, err = fmt.Fprintln(output, `{"ready":true}`); err != nil {
		return err
	}
	stopped := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, input)
		close(stopped)
		_ = server.Close()
	}()
	err = server.ServeTLS(listener, "", "")
	select {
	case <-stopped:
		return nil
	default:
		return err
	}
}

func main() {
	if err := serve(bufio.NewReaderSize(os.Stdin, 32<<10), os.Stdout); err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"error": err.Error()})
		os.Exit(1)
	}
}
