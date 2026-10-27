# Terranet ISP module wiring (T3 hooks, no upstream file edited): routes under /super_admin/terranet_isp and the sidebar entry.
Rails.application.routes.prepend do
  devise_scope :super_admin do
    scope path: 'super_admin', as: 'super_admin' do
      scope module: 'terranet/isp/admin', path: 'terranet_isp', as: 'terranet_isp' do
        root to: 'overview#index'
        scope 'accounts/:account_id', constraints: { account_id: /\d+/ } do
          get '/', to: 'overview#show', as: :overview
          get 'providers/:provider', to: 'providers#show', as: :provider, constraints: { provider: /wisphub|smartolt/ }
          patch 'providers/:provider', to: 'providers#update', constraints: { provider: /wisphub|smartolt/ }
          patch 'providers/:provider/secret', to: 'providers#secret', as: :provider_secret, constraints: { provider: /wisphub|smartolt/ }
          post 'providers/:provider/test', to: 'connection_checks#create', as: :provider_test, constraints: { provider: /wisphub|smartolt/ }
          get 'identity', to: 'bindings#index', as: :bindings
          post 'identity/:id/decision', to: 'bindings#decide', as: :binding_decision
          get 'audit', to: 'audit_events#index', as: :audit
        end
      end
    end
  end
end

Rails.application.config.to_prepare do
  SuperAdmin::NavigationHelper.prepend(Terranet::Isp::NavigationExtension)
end
