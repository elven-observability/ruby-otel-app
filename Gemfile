source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "8.1.4"
# Use postgresql as the database for Active Record
gem "pg", "1.7.0"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", "~> 7.2"

gem "opentelemetry-api", "1.11.1"
gem "opentelemetry-sdk", "1.13.1"
# Private retry hook: any exporter upgrade must update the guard and regressions.
gem "opentelemetry-exporter-otlp", "0.37.0"
gem "opentelemetry-instrumentation-rails", "0.42.0"
gem "opentelemetry-instrumentation-net_http", "0.29.2"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end
