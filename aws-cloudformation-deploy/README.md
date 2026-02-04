# aws-cloudformation-deploy

Composite action that deploys an AWS CloudFormation stack using `aws cloudformation deploy`.

## Required parameter overrides

This action enforces the following CloudFormation **template parameters** to be present in the final `--parameter-overrides` set (from `tag_*` inputs and/or `parameters_file` and/or `parameter_overrides`), and to have **non-empty** values:

- `TagApplication`
- `TagEnvironment`
- `TagOwner`
- `TagCostCenter`
- `TagManagedBy`
- `TagRepository` (must be an `http(s)` URL; auto-derived from the current GitHub repo when possible)
- `TagStackName` (auto-filled from `stack_name` if omitted)

## Example

```yaml
- uses: actaware/actions/aws-cloudformation-deploy@v1
  with:
    stack_name: dev-datahub-webapp
    template_file: infra/template.yaml
    region: us-east-1
    tag_application: datahub
    tag_environment: dev
    tag_owner: backend_team
    tag_cost_center: shared
    tag_managed_by: cloudformation
    # tag_repository defaults to the current repo URL if omitted
    parameters_file: infra/params/dev.env
    # or: parameter_overrides: >-
    #   TagApplication=datahub TagEnvironment=dev ...
```
