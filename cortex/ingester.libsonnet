{
  local volumeMount = $.core.v1.volumeMount,
  local pvc = $.core.v1.persistentVolumeClaim,
  local volume = $.core.v1.volume,
  local container = $.core.v1.container,
  local statefulSet = $.apps.v1beta1.statefulSet,

  _config+:: {
    wal_dir: '/wal_data',
    ingester+: {
      statefulset_replicas: 3,
      statefulset_disk: '150Gi',
    },
  },

  ingester_args::
    $._config.ringConfig +
    $._config.storeConfig +
    $._config.storageConfig +
    $._config.distributorConfig +  // This adds the distributor ring flags to the ingester.
    {
      target: 'ingester',

      // Ring config.
      'ingester.num-tokens': 512,
      'ingester.join-after': '30s',
      'ingester.max-transfer-retries': 60,  // Each retry is backed off by 5s, so 5mins for new ingester to come up.
      'ingester.heartbeat-period': '15s',
      'ingester.max-stale-chunk-idle': '5m',

      // Chunk building/flushing config.
      'ingester.chunk-encoding': 3,  // Bigchunk encoding
      'ingester.retain-period': '15m',
      'ingester.max-chunk-age': '6h',

      // Limits config.
      'ingester.max-chunk-idle': $._config.max_chunk_idle,
      'ingester.max-global-series-per-user': 1000000,  // 1M
      'ingester.max-global-series-per-metric': 100000,  // 100K
      'ingester.max-series-per-user': 0,  // Disabled in favour of the max global limit
      'ingester.max-series-per-metric': 0,  // Disabled in favour of the max global limit
      'limits.per-user-override-config': '/etc/cortex/overrides.yaml',
      'server.grpc-max-concurrent-streams': 100000,

      // WAL.
      'ingester.wal-enabled': true,
      'ingester.checkpoint-enabled': true,
      'ingester.recover-from-wal': true,
      'ingester.wal-dir': $._config.wal_dir,
      'ingester.checkpoint-duration': '15m',
      'ingester.tokens-file-path': $._config.wal_dir + '/tokens',
    } + (
      if $._config.memcached_index_writes_enabled then
        {
          // Setup index write deduping.
          'store.index-cache-write.memcached.hostname': 'memcached-index-writes.%(namespace)s.svc.cluster.local' % $._config,
          'store.index-cache-write.memcached.service': 'memcached-client',
        }
      else {}
    ),

  ingester_ports:: $.util.defaultPorts,

  local name = 'ingester',

  local ingester_pvc =
    pvc.new() +
    pvc.mixin.spec.resources.withRequests({ storage: $._config.ingester.statefulset_disk }) +
    pvc.mixin.spec.withAccessModes(['ReadWriteOnce']) +
    pvc.mixin.spec.withStorageClassName('fast') +
    pvc.mixin.metadata.withName('ingester-pvc'),

  ingester_container::
    container.new(name, $._images.ingester) +
    container.withPorts($.ingester_ports) +
    container.withArgsMixin($.util.mapToFlags($.ingester_args)) +
    container.withVolumeMountsMixin([
      volumeMount.new('ingester-pvc', $._config.wal_dir),
    ]) +
    $.util.resourcesRequests('4', '15Gi') +
    $.util.resourcesLimits(null, '25Gi') +
    $.util.readinessProbe +
    $.jaeger_mixin,

  statefulset_storage_config_mixin::
    statefulSet.mixin.spec.template.metadata.withAnnotationsMixin({ schemaID: $._config.schemaID },) +
    $.util.configVolumeMount('schema-' + $._config.schemaID, '/etc/cortex/schema'),

  ingester_statefulset_labels:: {},

  ingester_statefulset:
    statefulSet.new('ingester', $._config.ingester.statefulset_replicas, [$.ingester_container], ingester_pvc)
    .withServiceName('ingester')
    .withVolumes([volume.fromPersistentVolumeClaim('ingester-pvc', 'ingester-pvc')]) +
    statefulSet.mixin.metadata.withNamespace($._config.namespace) +
    statefulSet.mixin.metadata.withLabels({ name: 'ingester' }) +
    statefulSet.mixin.spec.template.metadata.withLabels({ name: 'ingester' } + $.ingester_statefulset_labels) +
    statefulSet.mixin.spec.selector.withMatchLabels({ name: 'ingester' }) +
    statefulSet.mixin.spec.template.spec.securityContext.withRunAsUser(0) +
    statefulSet.mixin.spec.template.spec.withTerminationGracePeriodSeconds(600) +
    statefulSet.mixin.spec.updateStrategy.withType('RollingUpdate') +
    $.statefulset_storage_config_mixin +
    $.util.configVolumeMount('overrides', '/etc/cortex') +
    $.util.podPriority('high') +
    $.util.antiAffinityStatefulSet,

  ingester_service_ignored_labels:: [],

  ingester_service:
    $.util.serviceFor($.ingester_statefulset, $.ingester_service_ignored_labels),

  local podDisruptionBudget = $.policy.v1beta1.podDisruptionBudget,

  ingester_pdb:
    podDisruptionBudget.new() +
    podDisruptionBudget.mixin.metadata.withName('ingester-pdb') +
    podDisruptionBudget.mixin.metadata.withLabels({ name: 'ingester-pdb' }) +
    podDisruptionBudget.mixin.spec.selector.withMatchLabels({ name: name }) +
    podDisruptionBudget.mixin.spec.withMaxUnavailable(1),
}
