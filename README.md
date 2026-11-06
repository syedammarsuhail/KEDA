# HPA vs KEDA: hands-on Kubernetes autoscaling lab

A self-contained, clone-and-run lab that shows **when plain HPA is enough and when you need KEDA**. One command builds a local cluster, installs everything, and deploys four live demos you can watch scale.

![architecture](docs/architecture.png)

| Demo | What it proves | Autoscaler |
|---|---|---|
| A. CPU side by side | HPA and KEDA's CPU trigger behave the same under identical load | HPA vs KEDA |
| B. Kafka consumer lag | A consumer sits near idle CPU while lag builds, so only lag-based scaling reacts | KEDA |
| C. Cron + scale to zero | Schedule-driven scaling and 0 -> N -> 0, which HPA cannot do | KEDA |

Everything lives in one namespace (`autoscale-demo`) and never touches anything else on your cluster.

## Quick start (about 5 minutes)

**Prerequisites:** [Docker](https://docs.docker.com/get-docker/), [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation), [kubectl](https://kubernetes.io/docs/tasks/tools/), [Helm](https://helm.sh/docs/intro/install/). About 4 CPUs and 6 GB RAM free for Docker.

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/hpa-vs-keda-autoscaling.git
cd hpa-vs-keda-autoscaling

make setup     # kind cluster + metrics-server + KEDA + all demo workloads
make cpu       # Demo A
make kafka     # Demo B
make cron      # Demo C
make destroy   # remove everything, including the kind cluster
```

Already have a cluster? Skip `make setup` and apply the manifests yourself. You need metrics-server (`kubectl top nodes` works) and KEDA installed (`kubectl get apiservice | grep keda` shows `True`):

```bash
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-hpa-demo.yaml
kubectl apply -f manifests/03-keda-cpu-demo.yaml
kubectl apply -f manifests/02-load-generator.yaml
kubectl apply -f manifests/04-kafka.yaml
kubectl apply -f manifests/05-kafka-consumer-keda.yaml
kubectl apply -f manifests/07-keda-cron-scale-to-zero.yaml
```

Sanity check before starting any demo:

```bash
kubectl get pods -n autoscale-demo
kubectl get hpa,scaledobject -n autoscale-demo
```

You should see the `php-apache` HPA at `0%/50%`, KEDA-created `keda-hpa-*` HPAs, and every ScaledObject `READY=True`.

## Demo A: HPA vs KEDA on CPU

Two identical CPU-hungry apps. One has a plain HPA, the other a KEDA `ScaledObject` with a CPU trigger. Both target 50% utilization, 1 to 4 replicas.

```bash
make cpu
# or by hand:
kubectl scale deploy/load-generator -n autoscale-demo --replicas=3
kubectl get hpa -n autoscale-demo -w
```

**Expect:** both HPAs climb above 50% and replicas rise from 1 toward 4. Scale the load generator to 0 and replicas drop back to 1 after about a minute (the demo shortens the HPA scale-down window to 60s; the Kubernetes default is 300s).

**Takeaway:** KEDA's CPU trigger just creates an HPA for you. For CPU-driven stateless services it adds a component and nothing else.

## Demo B: KEDA on Kafka consumer lag

A single-node KRaft Kafka broker, a topic with 3 partitions, and a deliberately slow consumer. A producer job writes 600 messages at 100 msg/s to create lag. KEDA scales on `lagThreshold: 10` per replica.

```bash
make kafka
# lag as Kafka sees it:
kubectl exec -n autoscale-demo deploy/kafka -- /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server kafka:9092 --describe --group demo-group
```

**Expect:** lag climbs toward 600, the HPA target shows a value well above 10 per replica, replicas go 1 -> 3 (the partition count), lag drains, then replicas return to 1 after the scale-down window. Meanwhile `kubectl top pod -l app=kafka-consumer` shows tiny CPU, which is exactly why a CPU HPA would never have reacted.

## Demo C: cron trigger and scale to zero

An nginx deployment with `minReplicaCount: 0` and a cron trigger asking for 3 replicas inside a time window. The script moves the window to start one minute from now.

```bash
make cron
```

**Expect:** 0 pods, then 3 when the window opens, then back to 0 about 30s after it closes.

## When to use HPA alone and when to use KEDA

**HPA alone** when CPU or memory is a good proxy for load: stateless web apps, APIs, frontends, gateways, anything that never needs zero pods.

**KEDA** when the signal lives outside the pod or you need something HPA can't do:

- Event-driven workloads (Kafka lag, RabbitMQ or SQS depth, Redis lists)
- Scale to zero and back
- Schedule-based scaling
- Prometheus or other external metrics without running an adapter
- Several signals on one app (it scales to whichever asks for the most replicas)

| Question | Answer | Use |
|---|---|---|
| Is CPU or memory a good proxy for load? | Yes | HPA |
| Is load a queue, topic backlog, schedule or external metric? | Yes | KEDA |
| Need scale to zero? | Yes | KEDA |
| Want to avoid extra components? | Yes | HPA |

## Gotchas worth knowing

1. **One autoscaler per deployment.** An HPA and a ScaledObject on the same deployment fight each other. KEDA creates its own HPA.
2. **`cooldownPeriod` only applies when scaling to zero.** Scale-down between replica counts is governed by the HPA `behavior` block, which these manifests set.
3. **Always set `maxReplicaCount`.** KEDA's default maximum is 100.
4. **Keep Kafka `maxReplicaCount` at or below the partition count.** Extra consumers sit idle. Expect a brief rebalance on every scale event.
5. **Keep `minReplicaCount: 1` for slow-starting apps** such as Java services. JVM start-up is too slow for scale to zero.
6. **Not every Kafka app is a lag-scaling candidate.** Consumers that use a random group ID on every start, or whose consumption is managed by another system, can't be tracked by lag.
7. **Don't autoscale crash-looping apps.** The HPA reads start-up CPU spikes as load and multiplies the problem. Fix health first.

## Repository layout

```
manifests/   numbered Kubernetes manifests (apply in order)
scripts/     setup.sh, demo-cpu.sh, demo-kafka.sh, demo-cron.sh, teardown.sh
kind/        local cluster config (1 control plane, 2 workers)
docs/        article draft, LinkedIn posts, diagrams, troubleshooting
.github/     CI: yamllint, shellcheck, kubeconform, and a real kind end-to-end check
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md). The usual suspects:

```bash
kubectl describe scaledobject kafka-consumer -n autoscale-demo
kubectl logs -n keda deploy/keda-operator --tail=50
kubectl logs -n autoscale-demo deploy/kafka --tail=30
```

## Notes

- The Kafka broker is a single node with `emptyDir` storage. It is for demos only.
- Images used: `registry.k8s.io/hpa-example`, `busybox:1.36`, `nginx:1.27-alpine`, `apache/kafka:3.8.0`.
- Pin a KEDA version with `KEDA_VERSION=x.y.z make setup`.

## License

MIT. See [LICENSE](LICENSE).
