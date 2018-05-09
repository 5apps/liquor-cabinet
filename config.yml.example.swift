development: &defaults
  maintenance: false
  swift: &swift_defaults
    host: "https://swift.example.com"
  redis:
    host: localhost
    port: 6379

test:
  <<: *defaults
  swift:
    host: "https://swift.example.com"

staging:
  <<: *defaults

production:
  <<: *defaults
