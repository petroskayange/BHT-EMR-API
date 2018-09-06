Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      resources :users
      get '/people/_names' => 'person_names#index'
      resources :people
      resources :roles
      resources :patients

      get '/locations/_districts' => 'locations#districts'
      get '/locations/_villages' => 'locations#villages'
      get '/locations/_traditional_authorities' => 'locations#traditional_authorities'
      resources :locations

      get '/encounters/_types' => 'encounter_types#index'
      resources :encounters

      resources :observations
    end
  end

  post '/api/v1/auth/login' => 'api/v1/users#login'
  post '/api/v1/auth/verify_token' => 'api/v1/users#check_token_validity'
end
