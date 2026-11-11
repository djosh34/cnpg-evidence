module github.com/djosh34/cnpg-evidence/bench

go 1.27.2

// The client is built against the pgfallback package of this checkout.
replace github.com/djosh34/cnpg-evidence => ..

require (
	github.com/cucumber/gherkin/go/v42 v42.0.0
	github.com/cucumber/godog v0.16.0
	github.com/cucumber/messages/go/v34 v34.2.0
	github.com/djosh34/cnpg-evidence v0.0.0-00010101000000-000000000000
	github.com/go-acme/lego/v4 v4.35.2
	github.com/jackc/pgx/v5 v5.12.0
	go.yaml.in/yaml/v3 v3.0.6
)

require (
	github.com/cenkalti/backoff/v5 v5.0.3 // indirect
	github.com/go-jose/go-jose/v4 v4.1.4 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/hashicorp/go-immutable-radix v1.3.1 // indirect
	github.com/hashicorp/go-memdb v1.3.5 // indirect
	github.com/hashicorp/golang-lru v0.5.4 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.3 // indirect
	github.com/miekg/dns v1.1.72 // indirect
	github.com/spf13/pflag v1.0.10 // indirect
	github.com/stretchr/testify v1.12.1 // indirect
	golang.org/x/crypto v0.58.0 // indirect
	golang.org/x/mod v0.41.0 // indirect
	golang.org/x/net v0.60.0 // indirect
	golang.org/x/sync v0.24.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/text v0.43.0 // indirect
	golang.org/x/tools v0.51.0 // indirect
)
