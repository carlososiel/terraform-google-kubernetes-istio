provider "google" {
  project = "${var.gcp_project}"
  region  = "${var.gcp_region}"
}

provider "kubernetes" {
  host     = "https://${google_container_cluster.gke_cluster.endpoint}"
  username = "${var.master_username}"
  password = "${var.master_password}"

  client_certificate     = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.client_certificate)}"
  client_key             = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.client_key)}"
  cluster_ca_certificate = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.cluster_ca_certificate)}"
}

provider "helm" {
  service_account = "tiller"
  namespace       = "kube-system"

  kubernetes {
    host     = "https://${google_container_cluster.gke_cluster.endpoint}"
    username = "${var.master_username}"
    password = "${var.master_password}"

    client_certificate     = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.client_certificate)}"
    client_key             = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.client_key)}"
    cluster_ca_certificate = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.cluster_ca_certificate)}"
  }
}

data "template_file" "kubeconfig" {
  template = "${file("${path.module}/templates/kube-config.tpl")}"

  vars {
    ca_certificate = "${google_container_cluster.gke_cluster.master_auth.0.cluster_ca_certificate}"
    server         = "https://${google_container_cluster.gke_cluster.endpoint}"
    username       = "${var.master_username}"
    password       = "${var.master_password}"
  }
}

resource "google_container_cluster" "gke_cluster" {
  name   = "${var.cluster_name}"
  region = "${var.gcp_region}"

  master_auth {
    username = "${var.master_username}"
    password = "${var.master_password}"
  }

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }
}

resource "google_container_node_pool" "gke_node_pool" {
  name       = "${var.cluster_name}-pool"
  region     = "${var.gcp_region}"
  cluster    = "${google_container_cluster.gke_cluster.name}"
  node_count = "${var.min_node_count}"

  autoscaling {
    min_node_count = "${var.min_node_count}"
    max_node_count = "${var.max_node_count}"
  }
}

resource "null_resource" "tiller_rbac" {
  provisioner "local-exec" {
    command = <<EOT
      echo "${data.template_file.kubeconfig.rendered}" > /tmp/kube-config
      export KUBECONFIG=/tmp/kube-config

      kubectl create serviceaccount tiller -n kube-system
      kubectl create clusterrolebinding tiller-cluster-admin --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
    EOT
  }
}

# TODO: helm provider was not configuring tiller automatically, installing manually for now.
resource "null_resource" "helm_init" {
  provisioner "local-exec" {
    command = <<EOT
      echo "${data.template_file.kubeconfig.rendered}" > /tmp/kube-config
      export KUBECONFIG=/tmp/kube-config
      helm init --tiller-namespace kube-system --service-account tiller --wait --upgrade
      helm repo update
    EOT
  }
}

resource "helm_repository" "istio_repository" {
  name = "istio_repository"
  url  = "${var.helm_repository}"
}

resource "helm_release" "istio" {
  name       = "istio"
  chart      = "istio"
  repository = "${helm_repository.istio_repository.metadata.0.name}"
  version    = "${var.istio_version}"

  namespace = "istio-system"

  set {
    name  = "global.mtls.enabled"
    value = true
  }

  set {
    name  = "sidecar-injector.enabled"
    value = true
  }

  set {
    name  = "prometheus.enabled"
    value = true
  }

  set {
    name  = "grafana.enabled"
    value = true
  }

  set {
    name  = "tracing.enabled"
    value = true
  }

  set {
    name  = "servicegraph.enabled"
    value = true
  }

  set {
    name  = "security.identityDomain"
    value = ""
  }

  depends_on = ["null_resource.helm_init", "null_resource.tiller_rbac"]
}
