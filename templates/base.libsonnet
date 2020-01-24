local timeouts = import "timeouts.libsonnet";
local tpus = import "tpus.libsonnet";

{
  BaseTest:: {
    local config = self,

    frameworkPrefix: error "Must specify `frameworkPrefix`",
    modelName: error "Must specify `modelName`",
    accelerator: tpus.v2_8 + tpus.Preemptible,
    # HACK: for format strings
    acceleratorName:: config.accelerator.name,
    mode: "functional",
    command: error "Must specify model `command`",
    frameworkVersion: error "Must specify `frameworkVersion`",
    image: error "Must specify mode `image`",
    imageTag: "latest",
    timeout: error "Must specify `timeout`", # 1 hour

    metricCollectionConfig: {
      write_to_bigquery: "True",
      bigquery_dataset_name: "xl_ml_metrics_dataset",
      bigquery_table_name: "xl_ml_metrics_table",
      default_aggregation_strategies: ["final"],
    },
    # TODO: increase min_num_datapoints_before_alerting. Low for debugging.
    regressionTestConfig: {
      write_metrics_to_stackdriver: "True",
      write_alerts_to_stackdriver: "True",
      min_num_datapoints_before_alerting: 1,
      base_threshold_expression: "v_mean + (v_stddev * 3.0)",
      base_comparison: "COMPARISON_GT",
    },

    testName:: "%(frameworkPrefix)s-%(modelName)s-%(mode)s-%(acceleratorName)s" % config,
    jobSpec:: {
      # Try 3 times before giving up
      backoffLimit: 2,
      activeDeadlineSeconds: config.timeout,
      template: {
        metadata: {
          annotations: {
            "tf-version.cloud-tpus.google.com": config.frameworkVersion,
          },
        },
        spec: {
          restartPolicy: "Never",
          containers: [
            {
              name: config.testName,
              image: "%(image)s:%(imageTag)s" % config,
	            # Use Docker image's entrypoint wrapper
              args: config.command,
              resources: {
                limits: config.accelerator.resource_limits,
              },
              env: [
                {
                  name: "TEST_NAME",
                  value: config.testName,
                },
                {
                  name: "POD_NAME",
                  valueFrom: {
                    fieldRef: {
                      fieldPath: "metadata.name"
                    },
                  },
                },
                {
                  name: "POD_UID",
                  valueFrom: {
                    fieldRef: {
                      fieldPath: "metadata.uid"
                    },
                  },
                },
                {
                  name: "POD_NAMESPACE",
                  valueFrom: {
                    fieldRef: {
                      fieldPath: "metadata.namespace"
                    },
                  },
                },
                {
                  name: "JOB_NAME",
                  valueFrom: {
                    fieldRef: {
                      fieldPath: "metadata.labels['job-name']",
                    },
                  },
                },
                {
                  name: "MODEL_DIR",
                  # TODO: Factor output bucket out into a ConfigMap
                  value: "gs://xl-ml-test-us-central1/k8s/%(modelName)s/%(mode)s/%(acceleratorName)s/$(JOB_NAME)" % config,
                },
                {
                  name: "METRIC_COLLECTION_CONFIG",
                  value: std.manifestJsonEx(config.metricCollectionConfig, " ")
                },
                {
                  name: "REGRESSION_TEST_CONFIG",
                  value: std.manifestJsonEx(config.regressionTestConfig, " ")
                },
              ],
            },
          ],
        },
      },
    },

    oneshotJob:: {
      apiVersion: "batch/v1",
      kind: "Job",
      metadata: {
        name: config.testName
      },
      spec: config.jobSpec,
    },

    cronJob(schedule):: {
      apiVersion: "batch/v1beta1",
      kind: "CronJob",
      metadata: {
        name: config.testName,
        namespace: "automated"
      },
      spec: {
        schedule: schedule,
        concurrencyPolicy: "Forbid",
        jobTemplate: {
          spec: config.jobSpec,
        },
      },
    },
  },
}