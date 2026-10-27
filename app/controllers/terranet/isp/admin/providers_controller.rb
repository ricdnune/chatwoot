class Terranet::Isp::Admin::ProvidersController < Terranet::Isp::Admin::BaseController
  before_action :set_credential

  def show
    @checks = Terranet::Isp::ConnectionCheck.where(credential_id: @credential.id).recent.limit(5) if @credential.persisted?
  end

  # Environment / subdomain only. The secret has its own action so it can never ride along with a settings form.
  def update
    @credential.assign_attributes(settings_params)
    if @credential.save
      audit!('provider.settings_updated', 'success', subject: @credential,
                                                     metadata: { provider: @credential.provider, environment: @credential.environment })
      redirect_to provider_path, notice: t('terranet_isp.flash.settings_saved')
    else
      audit!('provider.settings_updated', 'failure', subject: (@credential if @credential.persisted?), metadata: { provider: @credential.provider })
      @checks = []
      flash.now[:error] = t('terranet_isp.flash.settings_invalid')
      render :show, status: :unprocessable_entity
    end
  end

  def secret
    action = @credential.secret_configured? ? 'provider.secret_rotated' : 'provider.secret_set'
    @credential.replace_secret!(params.require(:credential)[:secret].to_s, actor: current_super_admin)
    audit!(action, 'success', subject: @credential, metadata: { provider: @credential.provider, environment: @credential.environment })
    redirect_to provider_path, notice: t('terranet_isp.flash.secret_saved')
  rescue Terranet::Isp::EncryptionNotConfigured
    audit!(action, 'failure', metadata: { provider: @credential.provider, error_code: 'encryption_not_configured' })
    redirect_to provider_path, alert: t('terranet_isp.flash.encryption_missing')
  rescue ArgumentError, ActiveRecord::RecordInvalid
    audit!(action, 'failure', metadata: { provider: @credential.provider, error_code: 'invalid_secret' })
    redirect_to provider_path, alert: t('terranet_isp.flash.secret_invalid')
  end

  private

  def set_credential
    @provider = params[:provider]
    @credential = Terranet::Isp::ProviderCredential.fetch_for(@account, @provider)
  end

  def settings_params
    allowed = @provider == 'smartolt' ? %i[subdomain] : %i[environment]
    params.fetch(:credential, {}).permit(*allowed)
  end

  def provider_path
    super_admin_terranet_isp_provider_path(account_id: @account.id, provider: @provider)
  end
end
