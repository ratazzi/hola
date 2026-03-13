# data_bag support for agent mode
# $_hola_params is injected by the provision engine as a parsed Hash
$_hola_params ||= {}

def data_bag(*keys)
  keys.reduce($_hola_params) do |val, key|
    return nil unless val.is_a?(Hash)
    val[key.to_s]
  end
end
