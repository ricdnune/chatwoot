require 'rails_helper'

RSpec.describe Terranet::Isp::ProviderCredential do
  let(:account) { create(:account) }
  let(:actor) { create(:user) }
  let(:credential) { described_class.fetch_for(account, 'wisphub') }
  let(:secret) { Terranet::IspHelpers::FAKE_SECRET }

  describe 'encryption at rest' do
    it 'never stores the secret in clear text and reads it back through the model only' do
      credential.replace_secret!(secret, actor: actor)
      raw = ActiveRecord::Base.connection.select_value("SELECT secret FROM terranet_isp_provider_credentials WHERE id = #{credential.id}")

      expect(raw).not_to include(secret)
      expect(ActiveRecord::Encryption.encryptor.encrypted?(raw)).to be(true)
      expect(described_class.find(credential.id).secret_value).to eq(secret)
    end

    it 'uses non-deterministic encryption (the same secret yields different ciphertexts)' do
      other = described_class.fetch_for(create(:account), 'wisphub')
      credential.replace_secret!(secret, actor: actor)
      other.replace_secret!(secret, actor: actor)

      expect(credential.secret_before_type_cast).not_to eq(other.secret_before_type_cast)
    end

    it 'fails closed: without encryption keys nothing is saved and nothing is readable' do
      credential.replace_secret!(secret, actor: actor)
      allow(Chatwoot).to receive(:encryption_configured?).and_return(false)

      expect { described_class.fetch_for(create(:account), 'wisphub').replace_secret!(secret, actor: actor) }
        .to raise_error(Terranet::Isp::EncryptionNotConfigured)
      expect(described_class.count).to eq(1)
      expect { described_class.find(credential.id).secret_value }.to raise_error(Terranet::Isp::EncryptionNotConfigured)
    end

    it 'refuses a clear-text value found in the column (legacy/unencrypted data is not trusted)' do
      credential.replace_secret!(secret, actor: actor)
      ActiveRecord::Base.connection.execute(
        "UPDATE terranet_isp_provider_credentials SET secret = 'plain-text-injected-value' WHERE id = #{credential.id}"
      )

      expect { described_class.find(credential.id).secret_value }.to raise_error(Terranet::Isp::Error, /not encrypted/)
    end
  end

  describe 'leak resistance' do
    before { credential.replace_secret!(secret, actor: actor) }

    it 'keeps the secret out of inspect, as_json, to_json and serializable_hash (attributes returns the plaintext by Rails design: never log it)' do
      rendered = [credential.inspect, credential.as_json.to_s, credential.to_json, credential.serializable_hash.to_s]

      rendered.each { |text| expect(text).not_to include(secret) }
      expect(credential.as_json).not_to have_key('secret')
    end

    it 'keeps the secret out of validation errors and exception messages' do
      credential.provider = 'bogus'
      credential.valid?

      expect(credential.errors.full_messages.join).not_to include(secret)
    end
  end

  describe 'secret format' do
    ['short', 'has space in it 12345', "line\nbreak-injection-1", 'x' * 513, 'ñandú-no-ascii-123'].each do |bad|
      it "rejects #{bad.truncate(24).inspect}" do
        expect { credential.replace_secret!(bad, actor: actor) }.to raise_error(ArgumentError)
        expect(credential).not_to be_secret_configured
      end
    end

    it 'records the rotation actor and date without keeping the previous value' do
      credential.replace_secret!(secret, actor: actor)
      first = credential.secret_before_type_cast
      credential.replace_secret!('mock-ok-fake-credential-0002', actor: actor)

      expect(credential.rotated_by_id).to eq(actor.id)
      expect(credential.rotated_at).to be_within(5.seconds).of(Time.current)
      expect(credential.secret_before_type_cast).not_to eq(first)
      expect(credential.secret_value).to eq('mock-ok-fake-credential-0002')
    end
  end

  describe 'validations' do
    it 'allows one credential per account and provider' do
      credential.replace_secret!(secret, actor: actor)

      expect(described_class.new(account_id: account.id, provider: 'wisphub')).not_to be_valid
      expect(described_class.new(account_id: create(:account).id, provider: 'wisphub')).to be_valid
    end

    it 'drops the stored secret when the environment changes (each environment has its own key)' do
      credential.replace_secret!(secret, actor: actor)
      credential.update!(environment: 'production')

      expect(credential).not_to be_secret_configured
      expect(credential.status).to eq('not_configured')
    end

    it 'accepts only structural SmartOLT subdomains' do
      build = ->(sub) { described_class.new(account_id: account.id, provider: 'smartolt', environment: 'production', subdomain: sub) }

      expect(build.call('terranet-demo')).to be_valid
      ['evil.com', 'a.b', '127.0.0.1:80', 'user@host', 'a/b', '-x', 'x-', '', nil, 'UPPER', 'a b', "a\nb", 'x' * 64].each do |bad|
        expect(build.call(bad)).not_to be_valid, "expected #{bad.inspect} to be rejected"
      end
    end

    it 'does not allow a subdomain on WispHub nor a sandbox SmartOLT' do
      expect(described_class.new(account_id: account.id, provider: 'wisphub', subdomain: 'x')).not_to be_valid
      expect(described_class.new(account_id: account.id, provider: 'smartolt', environment: 'sandbox', subdomain: 'x')).not_to be_valid
    end
  end
end
