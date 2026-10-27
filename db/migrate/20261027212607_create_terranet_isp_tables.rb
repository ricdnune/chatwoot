class CreateTerranetIspTables < ActiveRecord::Migration[7.2]
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def change
    create_table :terranet_isp_provider_credentials do |t|
      t.bigint :account_id, null: false
      t.string :provider, null: false
      t.string :environment, null: false, default: 'sandbox'
      t.string :subdomain
      t.text :secret
      t.string :status, null: false, default: 'not_configured'
      t.datetime :last_checked_at
      t.integer :last_latency_ms
      t.string :last_error_code
      t.datetime :rate_limited_until
      t.datetime :rotated_at
      t.bigint :rotated_by_id
      t.timestamps
    end
    add_index :terranet_isp_provider_credentials, %i[account_id provider], unique: true, name: 'idx_terranet_isp_credentials_account_provider'

    create_table :terranet_isp_connection_checks do |t|
      t.bigint :account_id, null: false
      t.bigint :credential_id, null: false
      t.bigint :actor_id
      t.boolean :ok, null: false, default: false
      t.integer :http_status
      t.integer :latency_ms
      t.string :error_code
      t.string :mode, null: false
      t.datetime :created_at, null: false
    end
    add_index :terranet_isp_connection_checks, %i[credential_id created_at], name: 'idx_terranet_isp_checks_credential_created'

    create_table :terranet_isp_audit_events do |t|
      t.bigint :account_id, null: false
      t.bigint :actor_id
      t.string :action, null: false
      t.string :outcome, null: false
      t.string :subject_type
      t.bigint :subject_id
      t.string :request_id
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :terranet_isp_audit_events, %i[account_id created_at], name: 'idx_terranet_isp_audit_account_created'

    create_table :terranet_isp_bindings do |t|
      t.bigint :account_id, null: false
      t.bigint :contact_id, null: false
      t.string :wisphub_service_id, null: false
      t.string :smartolt_external_id
      t.string :matched_by, null: false
      t.string :status, null: false, default: 'candidate'
      t.string :decision_reason
      t.bigint :decided_by_id
      t.datetime :decided_at
      t.timestamps
    end
    add_index :terranet_isp_bindings, %i[account_id contact_id wisphub_service_id], unique: true, name: 'idx_terranet_isp_bindings_unique_link'
    add_index :terranet_isp_bindings, %i[account_id status], name: 'idx_terranet_isp_bindings_account_status'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
end
