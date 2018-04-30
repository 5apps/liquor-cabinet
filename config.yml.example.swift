development: &defaults
  maintenance: false
  # uncomment this section
  swift: &swift_defaults
    host: "https://swift.example.com"
  # Redis is needed for the swift backend
  redis:
    host: localhost
    port: 6379

test:
  <<: *defaults
  swift:
    host: "https://swift.example.com"
  redis:
    host: localhost
    port: 6379

staging:
  <<: *defaults

production:
  <<: *defaults
