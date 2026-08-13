{{/*
Calico Enterprise renamed and rehomed the Manager and the MCM tunnel secret in 3.23:

  3.21 / 3.22                              3.23+
  ns  tigera-manager                       ns  calico-system
  svc tigera-manager                       svc calico-manager
  svc tigera-manager-mcm                   svc calico-manager-mcm
  label k8s-app: tigera-manager            label k8s-app: calico-manager
  secret tigera-management-cluster-...     secret calico-management-cluster-...

Every reference below is derived from the single value `ce.version`, so changing CE
version in one place moves all of them together, in both directions. Hardcoding any
of these names is what broke the MCM tunnel on the 3.21->3.23 upgrade AND again on
the 3.23->3.21 rollback: Argo reports Synced either way, because the objects are all
valid, they just point at services that do not exist.
*/}}

{{- define "ce.isPost323" -}}
{{- semverCompare ">=3.23.0-0" (.Values.ce.version | trimPrefix "v") -}}
{{- end -}}

{{- define "ce.managerNamespace" -}}
{{- if eq (include "ce.isPost323" .) "true" -}}calico-system{{- else -}}tigera-manager{{- end -}}
{{- end -}}

{{- define "ce.managerService" -}}
{{- if eq (include "ce.isPost323" .) "true" -}}calico-manager{{- else -}}tigera-manager{{- end -}}
{{- end -}}

{{- define "ce.managerMcmService" -}}
{{- if eq (include "ce.isPost323" .) "true" -}}calico-manager-mcm{{- else -}}tigera-manager-mcm{{- end -}}
{{- end -}}

{{- define "ce.managerAppLabel" -}}
{{- if eq (include "ce.isPost323" .) "true" -}}calico-manager{{- else -}}tigera-manager{{- end -}}
{{- end -}}

{{/*
The name Voltron reads its serving cert from. The 3.23 CRD default flipped to the
calico-* name and marks the tigera-* name deprecated, so supplying a cert under the
old name on 3.23 gets it silently orphaned and the operator self-signs its own CA.
*/}}
{{- define "ce.tunnelSecretName" -}}
{{- if eq (include "ce.isPost323" .) "true" -}}calico-management-cluster-connection{{- else -}}tigera-management-cluster-connection{{- end -}}
{{- end -}}

{{/* "<namespace>/<service>:<port>" as ingress-nginx wants it for a TCP passthrough. */}}
{{- define "ce.mcmTcpTarget" -}}
{{ include "ce.managerNamespace" . }}/{{ include "ce.managerMcmService" . }}:9449
{{- end -}}
