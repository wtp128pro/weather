fs = import('fs')

# Each module directory exports a `<module>_dep` declare_dependency. Modules are
# listed in dependency order (a module may only use deps of earlier ones) and
# are skipped while their directory does not exist yet.
foreach module : ['core', 'net', 'providers', 'blend', 'service', 'storage', 'sched', 'widgets', 'ui']
  if fs.is_dir(module)
    subdir(module)
  endif
endforeach
