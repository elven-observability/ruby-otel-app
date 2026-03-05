Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get "health", to: "health#show"
  get "internal/ping", to: "internal#ping"
  post "checkout", to: "checkout#create"
end
