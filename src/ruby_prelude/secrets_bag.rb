# secrets_bag support for sensitive data (passwords, API keys, etc.)
# $_hola_secrets is injected by the provision engine as a parsed Hash
$_hola_secrets ||= {}

def secrets_bag(*keys)
  keys.reduce($_hola_secrets) do |val, key|
    return nil unless val.is_a?(Hash)
    val[key.to_s]
  end
end
