if is_plat("windows") then
  set_toolchains("clang-cl")
else 
  set_toolchains("clang")
end

set_warnings("allextra")

add_requires("libcurl", {system = false, configs = { openssl = true }})
add_requires("openssl", {system = false})
add_requires("libpq", {system = false})

target("bonzai-standard")
  add_rules("mode.release")
  add_files("src/**.c")
  add_files("../runtime/src/**.c")
  add_includedirs("include")
  add_includedirs("../runtime/include")

  add_packages("libcurl", "openssl", "libpq")

  set_kind("shared")
  set_targetdir("bin")
  set_optimize("fastest")
  set_basename("bindings")
  set_prefixname("")

target("bonzai-standard-test")
  add_rules("mode.debug", "mode.profile")
  add_files("src/**.c")
  add_files("../runtime/src/**.c")
  add_includedirs("include")
  add_includedirs("../runtime/include")

  add_packages("libcurl", "openssl", "libpq")

  set_kind("shared")
  set_targetdir("bin")
  set_symbols("debug")
  add_cxflags("-pg")
  add_ldflags("-pg")
  set_basename("bindings-test")
  set_prefixname("")
