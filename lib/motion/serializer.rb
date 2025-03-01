# frozen_string_literal: true

require "digest"
require "lz4-ruby"
require "active_support/message_encryptor"

require "motion"

module ActiveSupport
  class MessageEncryptor
    module NullVerifier # :nodoc:
      def self.verify(value)\
        value
      end

      def self.generate(value)
        value
      end
    end

    def encrypt_and_sign_old(value, expires_at: nil, expires_in: nil, purpose: nil)
      (@verifier || NullVerifier).generate(encrypt(value))
    end

    def decrypt_and_verify_old(data, purpose: nil, **)
      decrypt((@verifier || NullVerifier).verify(data))
    end
  end
end

module Motion
  class Serializer
    HASH_PEPPER = "Motion"
    private_constant :HASH_PEPPER

    NULL_BYTE = "\0"

    attr_reader :secret, :revision

    def self.minimum_secret_byte_length
      ActiveSupport::MessageEncryptor.key_len
    end

    def initialize(
      secret: Motion.config.secret,
      revision: Motion.config.revision
    )
      unless secret.each_byte.count >= self.class.minimum_secret_byte_length
        raise BadSecretError.new(self.class.minimum_secret_byte_length)
      end

      raise BadRevisionError if revision.include?(NULL_BYTE)

      @secret = secret
      @revision = revision
    end

    def weak_digest(component)
      dump(component).hash
    end

    def serialize(component)
      state = deflate(dump(component))
      state_with_revision = "#{revision}#{NULL_BYTE}#{state}"

      [
        salted_digest(state_with_revision),
        encrypt_and_sign(state_with_revision)
      ]
    end

    def deserialize(serialized_component)
      state_with_revision = decrypt_and_verify(serialized_component)
      serialized_revision, state = state_with_revision.split(NULL_BYTE, 2)
      component = load(inflate(state))

      if revision == serialized_revision
        component
      else
        component.class.upgrade_from(serialized_revision, component)
      end
    end

    private

    def dump!(component)
      Marshal.dump(component)
    end

    def dump(component)
      dump!(component)
    rescue TypeError => e
      failing_ivars = []

      component.marshal_dump.each do |ivar_name, ivar_value|
        dump!(ivar_value)
      rescue TypeError
        failing_ivars << ivar_name
      end

      raise UnrepresentableStateError.new(component, e.message, failing_ivars)
    end

    def load(state)
      Marshal.load(state)
    end

    def deflate(dumped_component)
      LZ4.compress(dumped_component)
    end

    def inflate(deflated_state)
      LZ4.uncompress(deflated_state)
    end

    def encrypt_and_sign(cleartext)
      encryptor.encrypt_and_sign_old(cleartext)
    end

    def decrypt_and_verify(cypertext)
      encryptor.decrypt_and_verify_old(cypertext)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage,
      ActiveSupport::MessageVerifier::InvalidSignature
      raise InvalidSerializedStateError
    end

    def salted_digest(input)
      Digest::SHA256.base64digest(hash_salt + input)
    end

    def encryptor
      @encryptor ||= ActiveSupport::MessageEncryptor.new(derive_encryptor_key)
    end

    def hash_salt
      @hash_salt ||= derive_hash_salt
    end

    def derive_encryptor_key
      secret.byteslice(0, self.class.minimum_secret_byte_length)
    end

    def derive_hash_salt
      Digest::SHA256.digest(HASH_PEPPER + secret)
    end
  end
end
