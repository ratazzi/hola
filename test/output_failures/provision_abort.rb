Hola::Resources.with_resource_scope "release_bundle", "fatal demo application", :create do
  execute "fatal nested packaging step" do
    command "printf 'packaging started\\n'; printf 'package input is missing\\n' >&2; exit 29"
    live_stream true
  end
end
