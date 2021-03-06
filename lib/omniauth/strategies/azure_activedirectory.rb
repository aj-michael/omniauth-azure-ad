require 'jwt'
require 'omniauth'
require 'openssl'
require 'securerandom'

module OmniAuth
  module Strategies
    # A strategy for authentication against Azure Active Directory.
    class AzureActiveDirectory
      include OmniAuth::AzureActiveDirectory
      include OmniAuth::Strategy

      class OAuthError < StandardError; end

      ##
      # The client id (key) and tenant must be configured when the OmniAuth
      # middleware is installed. Example:
      #
      #    require 'omniauth'
      #    require 'omniauth-azure-ad'
      #
      #    use OmniAuth::Builder do
      #      provider :azuread, ENV['AAD_KEY'], ENV['AAD_TENANT']
      #    end
      #
      args [:client_id, :tenant]
      option :client_id, nil
      option :tenant, nil

      # Field renaming is an attempt to fit the OmniAuth recommended schema as
      # best as possible.
      #
      # @see https://github.com/intridea/omniauth/wiki/Auth-Hash-Schema
      uid { @claims['sub'] }
      info do
        { name: @claims['name'],
          email: @claims['email'] || @claims['upn'],
          first_name: @claims['given_name'],
          last_name: @claims['family_name'] }
      end
      credentials { { code: @code } }
      extra do
        { session_state: @session_state,
          raw_info:
            { id_token: @id_token,
              id_token_claims: @claims,
              id_token_header: @header } }
      end

      DEFAULT_RESPONSE_TYPE = 'code id_token'
      DEFAULT_RESPONSE_MODE = 'form_post'
      DEFAULT_SIGNING_KEYS_URL =
        'https://login.windows.net/common/discovery/keys'

      ##
      # Overridden method from OmniAuth::Strategy. This is the first step in the
      # authentication process.
      def request_phase
        redirect authorize_endpoint_url
      end

      ##
      # Overridden method from OmniAuth::Strategy. This is the second step in
      # the authentication process. It is called after the user enters
      # credentials at the authorization endpoint.
      def callback_phase
        error = request.params['error_reason'] || request.params['error']
        fail(OAuthError, error) if error
        @session_state = request.params['session_state']
        @id_token = request.params['id_token']
        @code = request.params['code']
        @claims, @header = validate_id_token(@id_token)
        super
      end

      private

      ##
      # Constructs a one-time-use authorize_endpoint. This method will use
      # a new nonce on each invocation.
      #
      # @return String
      def authorize_endpoint_url
        uri = URI(openid_config['authorization_endpoint'])
        uri.query = URI.encode_www_form(client_id: client_id,
                                        redirect_uri: callback_url,
                                        response_mode: response_mode,
                                        response_type: response_type,
                                        nonce: new_nonce)
        uri.to_s
      end

      ##
      # The client id of the calling application. This must be configured where
      # AzureAD is installed as an OmniAuth strategy.
      #
      # @return String
      def client_id
        return options.client_id if options.client_id
        fail StandardError, 'No client_id specified in AzureAD configuration.'
      end

      ##
      # The expected id token issuer taken from the discovery endpoint.
      #
      # @return String
      def issuer
        openid_config['issuer']
      end

      ##
      # Fetches the current signing keys for Azure AD. Note that there should
      # always two available, and that they have a 6 week rollover.
      #
      # Each key is a hash with the following fields:
      #   kty, use, kid, x5t, n, e, x5c
      #
      # @return Array[Hash]
      def fetch_signing_keys
        response = JSON.parse(Net::HTTP.get(URI(signing_keys_url)))
        response['keys']
      rescue JSON::ParserError
        raise StandardError, 'Unable to fetch AzureAD signing keys.'
      end

      ##
      # Fetches the OpenId Connect configuration for the AzureAD tenant. This
      # contains several import values, including:
      #
      #   authorization_endpoint
      #   token_endpoint
      #   token_endpoint_auth_methods_supported
      #   jwks_uri
      #   response_types_supported
      #   response_modes_supported
      #   subject_types_supported
      #   id_token_signing_alg_values_supported
      #   scopes_supported
      #   issuer
      #   claims_supported
      #   microsoft_multi_refresh_token
      #   check_session_iframe
      #   end_session_endpoint
      #   userinfo_endpoint
      #
      # @return Hash
      def fetch_openid_config
        JSON.parse(Net::HTTP.get(URI(openid_config_url)))
      rescue JSON::ParserError
        raise StandardError, 'Unable to fetch OpenId configuration for ' \
                             'AzureAD tenant.'
      end

      ##
      # Generates a new nonce for one time use. Stores it in the session so
      # multiple users don't share nonces. All nonces should be generated by
      # this method.
      #
      # @return String
      def new_nonce
        session['omniauth-azure-ad.nonce'] = SecureRandom.uuid
      end

      ##
      # A memoized version of #fetch_openid_config.
      #
      # @return Hash
      def openid_config
        @openid_config ||= fetch_openid_config
      end

      ##
      # The location of the OpenID configuration for the tenant.
      #
      # @return String
      def openid_config_url
        "https://login.windows.net/#{tenant}/.well-known/openid-configuration"
      end

      ##
      # Returns the most recent nonce for the session and deletes it from the
      # session.
      #
      # @return String
      def read_nonce
        session.delete('omniauth-azure-ad.nonce')
      end

      ##
      # The response_type that will be set in the authorization request query
      # parameters. Can be overridden by the client, but it shouldn't need to
      # be.
      #
      # @return String
      def response_type
        options[:response_type] || DEFAULT_RESPONSE_TYPE
      end

      ##
      # The response_mode that will be set in the authorization request query
      # parameters. Can be overridden by the client, but it shouldn't need to
      # be.
      #
      # @return String
      def response_mode
        options[:response_mode] || DEFAULT_RESPONSE_MODE
      end

      ##
      # The keys used to sign the id token JWTs. This is just a memoized version
      # of #fetch_signing_keys.
      #
      # @return Array[Hash]
      def signing_keys
        @signing_keys ||= fetch_signing_keys
      end

      ##
      # The location of the AzureAD public signing keys. In reality, this is
      # static but since it could change in the future, we try and parse it from
      # the discovery endpoint if possible.
      #
      # @return String
      def signing_keys_url
        if openid_config.include? 'jwks_uri'
          openid_config['jwks_uri']
        else
          DEFAULT_SIGNING_KEYS_URL
        end
      end

      ##
      # The tenant of the calling application. Note that this must be
      # explicitly configured when installing the AzureAD OmniAuth strategy.
      #
      # @return String
      def tenant
        return options.tenant if options.tenant
        fail StandardError, 'No tenant specified in AzureAD configuration.'
      end

      ##
      # Verifies the signature of the id token as well as the exp, nbf, iat,
      # iss, and aud fields.
      #
      # See OpenId Connect Core 3.1.3.7 and 3.2.2.11.
      #
      # return Claims, Header
      def validate_id_token(id_token)
        # The second parameter is the public key to verify the signature.
        # However, that key is overridden by the value of the executed block
        # if one is present.
        claims, header =
          JWT.decode(id_token, nil, true, verify_options) do |header|
            # There should always be one key from the discovery endpoint that
            # matches the id in the JWT header.
            x5c = signing_keys.find do |key|
              key['kid'] == header['kid']
            end['x5c'].first
            # The key also contains other fields, such as n and e, that are
            # redundant. x5c is sufficient to verify the id token.
            OpenSSL::X509::Certificate.new(JWT.base64url_decode(x5c)).public_key
          end
        return claims, header if claims['nonce'] == read_nonce
        fail JWT::DecodeError, 'Returned nonce did not match.'
      end

      ##
      # The options passed to the Ruby JWT library to verify the id token.
      # Note that these are not all the checks we perform. Some (like nonce)
      # are not handled by the JWT API and are checked manually in
      # #validate_id_token.
      #
      # @return Hash
      def verify_options
        { verify_expiration: true,
          verify_not_before: true,
          verify_iat: true,
          verify_iss: true,
          'iss' => issuer,
          verify_aud: true,
          'aud' => client_id }
      end
    end
  end
end

OmniAuth.config.add_camelization 'azure_activedirectory', 'AzureActiveDirectory'
