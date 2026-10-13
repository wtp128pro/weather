fs = import('fs')

# Each provider directory defines `<name>_dep` (a declare_dependency of its
# static library) and is skipped while the directory does not exist yet. The
# loop appends every <name>_dep to provider_deps, and providers_dep exports
# them all (plus the network layer) to the modules above.
provider_deps = []
foreach provider_name : ['openmeteo', 'nws', 'metno']
  if fs.is_dir(provider_name)
    subdir(provider_name)
    provider_deps += get_variable(provider_name + '_dep')
  endif
endforeach

providers_dep = declare_dependency(dependencies: [net_dep] + provider_deps)
