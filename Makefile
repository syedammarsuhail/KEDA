.PHONY: setup cpu kafka cron status clean destroy lint

setup:     ## kind cluster + metrics-server + KEDA + demo workloads
	./scripts/setup.sh

cpu:       ## Demo A: HPA vs KEDA on CPU
	./scripts/demo-cpu.sh

kafka:     ## Demo B: KEDA on Kafka consumer lag
	./scripts/demo-kafka.sh

cron:      ## Demo C: KEDA cron trigger and scale to zero
	./scripts/demo-cron.sh

status:
	kubectl get deploy,hpa,scaledobject -n autoscale-demo

clean:     ## delete the demo namespace
	./scripts/teardown.sh

destroy:   ## delete namespace and the kind cluster
	./scripts/teardown.sh --cluster

lint:      ## same checks as CI (needs yamllint, kubeconform, shellcheck)
	yamllint -c .yamllint manifests kind
	kubeconform -strict -ignore-missing-schemas -summary manifests kind
	shellcheck scripts/*.sh
