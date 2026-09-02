
{{/*
generate imagePullSecrets for installation and deployments
by combining imagePullSecretRerefences with imagePullSecrets.
*/}}

{{- define "tigera-prometheus-operator.imagePullSecrets" -}}
{{- $secrets := default list .Values.imagePullSecretReferences -}}
{{- range $key, $val := .Values.imagePullSecrets -}}
  {{- $secrets = append $secrets (dict "name" $key) -}}
{{- end -}}
{{ $secrets | toYaml }}
{{- end -}}
