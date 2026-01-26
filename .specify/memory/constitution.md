<!--
Sync Impact Report:
Version change: [NEW] → 1.0.0
Modified principles: None (initial version)
Added sections: All sections (initial version)
Removed sections: None
Templates status:
  ✅ plan-template.md - Constitution Check section aligns with principles
  ✅ spec-template.md - Requirements structure supports declarative infrastructure
  ✅ tasks-template.md - Task organization supports independent deployment verification
  ✅ checklist-template.md - Generic structure compatible
  ✅ agent-file-template.md - Generic structure compatible
Follow-up TODOs: None
-->

# FluxCD Kustomizations Constitution

## Core Principles

### I. Reusability First

All FluxCD kustomizations MUST be designed for reusability across multiple clusters.
Reusable kustomizations MUST reside in the `./base` folder and be self-contained with
clear documentation. Each base kustomization MUST have a single, well-defined purpose
and MUST NOT include cluster-specific configuration values.

**Rationale**: Enables consistent deployments across environments while minimizing
duplication and maintenance overhead. Base kustomizations serve as the source of truth
for application configurations.

### II. Cluster-Specific Overlays

Cluster-specific kustomizations MUST reside in `./clusters/<cluster-name>/` directories.
Each cluster overlay MUST only reference base kustomizations and provide
cluster-specific configuration through patches or variable substitutions. Cluster
overlays MUST NOT contain application logic or complete resource definitions that
should be in base.

**Rationale**: Separates environment-specific concerns from application definitions,
making it clear what differs between clusters and enabling independent cluster
lifecycle management.

### III. Declarative Infrastructure (NON-NEGOTIABLE)

All Kubernetes resources MUST be declared in YAML files managed by FluxCD. No manual
`kubectl apply` commands or imperative modifications are permitted for managed
resources. Every desired state change MUST be committed to version control and
applied through FluxCD reconciliation.

**Rationale**: Ensures GitOps principles are maintained, provides full audit trail,
enables disaster recovery, and prevents configuration drift between declared and
actual cluster state.

### IV. Validation Before Commit

All kustomization changes MUST be validated using `kustomize build` before committing.
Changes MUST pass YAML linting and Kubernetes schema validation. Breaking changes to
base kustomizations MUST be verified against all consuming cluster overlays.

**Rationale**: Catches syntax errors, structural issues, and breaking changes before
they reach clusters, preventing failed FluxCD reconciliations and potential outages.

### V. Documentation and Context

Every base kustomization MUST include a README.md documenting its purpose, required
variables, dependencies, and usage examples. Cluster directories MUST document
cluster-specific configuration decisions and any deviations from standard patterns.

**Rationale**: Enables team members to understand infrastructure decisions, reduces
onboarding time, and provides context for future modifications without requiring
tribal knowledge.

## Security and Compliance

### Secret Management

Secrets MUST NOT be committed to the repository in plain text. Secrets MUST be
managed through sealed-secrets, SOPS, external secret operators, or other secure
secret management solutions compatible with FluxCD. Secret references in
kustomizations MUST clearly indicate the secret management mechanism used.

### Resource Limits

All workload resources (Deployments, StatefulSets, DaemonSets) MUST define resource
requests and limits. NetworkPolicies SHOULD be defined for workloads requiring
network isolation. Security contexts SHOULD follow least-privilege principles.

## Development Workflow

### Branch Strategy

Changes MUST be developed on feature branches following the pattern
`feature/<description>` or `fix/<description>`. Pull requests MUST be reviewed by at
least one team member before merging to main. The main branch represents the desired
state for all clusters.

### Testing Strategy

Changes SHOULD be tested in a non-production cluster before being applied to
production. Breaking changes MUST include a migration plan documented in the pull
request. FluxCD reconciliation status MUST be monitored after merging changes.

### Directory Structure Enforcement

The following structure MUST be maintained:

```
./base/                    # Reusable kustomizations
  ├── <component-name>/    # One directory per component
  │   ├── kustomization.yaml
  │   ├── <resources>.yaml
  │   └── README.md
./clusters/                # Cluster-specific overlays
  ├── <cluster-name>/      # One directory per cluster
  │   ├── kustomization.yaml
  │   └── <component-overlays>/
```

## Governance

### Amendment Process

Constitution amendments require:
1. Documented proposal explaining the change rationale
2. Review and approval from infrastructure team leads
3. Migration plan for existing kustomizations if applicable
4. Updated version number following semantic versioning

### Versioning Policy

- **MAJOR**: Breaking changes to structure, removal of required principles
- **MINOR**: New principles added, expanded guidance
- **PATCH**: Clarifications, documentation improvements, non-semantic fixes

### Compliance

All pull requests MUST verify compliance with this constitution. Complexity or
deviations MUST be explicitly justified in the pull request description. Infrastructure
reviews MUST verify adherence to reusability, security, and documentation principles.

**Version**: 1.0.0 | **Ratified**: 2026-01-25 | **Last Amended**: 2026-01-25
