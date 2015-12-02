Rails.application.routes.draw do
  devise_for :users, controllers: { omniauth_callbacks: "users/omniauth_callbacks" }

  # Hoptoad Notifier Routes
  match '/notifier_api/v2/notices' => 'notices#create', via: [:get, :post]
  get '/locate/:id' => 'notices#locate', :as => :locate

  resources :notices, only: [:show]
  resources :users do
    member do
      delete :unlink_github
    end
  end

  resources :site_config, only: [:index] do
    collection do
      put :update
    end
  end

  resources :problems, only: [:index] do
    collection do
      post :destroy_several
      post :resolve_several
      post :unresolve_several
      post :merge_several
      post :unmerge_several
      get :search
    end
  end

  resources :apps do
    resources :problems do
      resources :notices
      resources :comments, only: [:create, :destroy]

      collection do
        post :destroy_all
      end

      member do
        put :resolve
        put :unresolve
        post :create_issue
        delete :unlink_issue
      end
    end
    resources :watchers, only: [:destroy, :update]
    member do
      post :regenerate_api_key
    end
  end

  namespace :api do
    namespace :v1 do
      resources :problems, only: [:index, :show], defaults: { format: 'json' }
      resources :notices,  only: [:index], defaults: { format: 'json' }
      resources :stats, only: [], defaults: { format: 'json' } do
        collection do
          get :app
        end
      end
    end
  end

  match '/api/v3/projects/:project_id/create-notice' => 'api/v3/notices#create', via: [:post]
  match '/api/v3/projects/:project_id/notices' => 'api/v3/notices#create', via: [:post]

  root to: 'apps#index'
end
