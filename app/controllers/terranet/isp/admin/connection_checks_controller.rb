class Terranet::Isp::Admin::ConnectionChecksController < Terranet::Isp::Admin::BaseController
  def create
    credential = Terranet::Isp::ProviderCredential.for_account(@account).find_by!(provider: params[:provider])
    outcome = Terranet::Isp::ConnectionTester.new(credential: credential, actor: current_super_admin, request_id: request.request_id).call
    flash_key = outcome.ok ? :notice : :alert
    redirect_to super_admin_terranet_isp_provider_path(account_id: @account.id, provider: credential.provider),
                flash_key => t(outcome.ok ? 'terranet_isp.flash.check_ok' : 'terranet_isp.flash.check_failed')
  end
end
