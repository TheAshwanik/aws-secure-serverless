provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias  = "virginia"
  region = "us-east-1"
}

resource "null_resource" "pkg_python_dependencies" {
  for_each = toset(var.function_list)

  triggers = {
    script_hash = filesha256("${path.module}/create_package.sh")
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/create_package.sh"

    environment = {
      runtime     = "python3.9"
      func_dir    = each.value
      path_module = path.module
      path_cwd    = path.cwd
    }
  }
}

data "archive_file" "lambda_zip_pkg" {
  for_each    = toset(var.function_list)
  depends_on  = [null_resource.pkg_python_dependencies]
  source_dir  = "${path.cwd}/${each.value}-pkg/"
  output_path = "${each.value}.zip"
  type        = "zip"
}

resource "aws_dynamodb_table" "dynamodb" {
  name           = var.db_name
  billing_mode   = "PROVISIONED"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "timestamp"

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "type"
    type = "S"
  }

  attribute {
    name = "payload"
    type = "S"
  }

  global_secondary_index {
    name            = "typeAndPayload"
    hash_key        = "type"
    range_key       = "payload"
    write_capacity  = 1
    read_capacity   = 1
    projection_type = "ALL"
  }
}

data "aws_iam_policy" "AWSLambdaBasicExecutionRole" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "in_line_policy_reader" {
  statement {
    effect = "Allow"

    resources = [
      aws_dynamodb_table.dynamodb.arn
    ]

    actions = [
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:GetItem"
    ]
  }
}

data "aws_iam_policy_document" "invoke_policy_authorizer" {
  statement {
    effect = "Allow"

    resources = [
      aws_lambda_function.aws_lambda_authorizer.arn
    ]

    actions = [
      "lambda:InvokeFunction"
    ]
  }
}

data "aws_iam_policy_document" "in_line_policy_writer" {
  statement {
    effect = "Allow"

    resources = [
      aws_dynamodb_table.dynamodb.arn
    ]

    actions = [
      "dynamodb:PutItem"
    ]
  }
}

resource "aws_iam_role" "lambda_role_authorizer" {
  name               = join("-", ["LambdaRole", var.app_name, "authorizer"])
  assume_role_policy = data.aws_iam_policy_document.assume-role-policy.json
}

resource "aws_iam_role" "lambda_role_reader" {
  name               = join("-", ["LambdaRole", var.app_name, "reader"])
  assume_role_policy = data.aws_iam_policy_document.assume-role-policy.json

  inline_policy {
    name   = "DynamoDB"
    policy = data.aws_iam_policy_document.in_line_policy_reader.json
  }
}

resource "aws_iam_role" "lambda_role_writer" {
  name               = join("-", ["LambdaRole", var.app_name, "writer"])
  assume_role_policy = data.aws_iam_policy_document.assume-role-policy.json

  inline_policy {
    name   = "DynamoDB"
    policy = data.aws_iam_policy_document.in_line_policy_writer.json
  }
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attachment_authorizer" {
  policy_arn = data.aws_iam_policy.AWSLambdaBasicExecutionRole.arn
  role       = aws_iam_role.lambda_role_authorizer.name
}
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment_reader" {
  policy_arn = data.aws_iam_policy.AWSLambdaBasicExecutionRole.arn
  role       = aws_iam_role.lambda_role_reader.name
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attachment_writer" {
  policy_arn = data.aws_iam_policy.AWSLambdaBasicExecutionRole.arn
  role       = aws_iam_role.lambda_role_writer.name
}

resource "aws_secretsmanager_secret" "JWT" {
  name = join("-", [var.app_name, "JWTTokenAuthorizer"])
  recovery_window_in_days = 0

  lifecycle {
    create_before_destroy = true
  }
}

resource "random_password" "JWTSecret" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret_version" "JWTSecret" {
  secret_id     = aws_secretsmanager_secret.JWT.id
  secret_string = jsonencode({ token = random_password.JWTSecret.result })
}

data "aws_secretsmanager_secret_version" "JWTSecret" {
  secret_id = aws_secretsmanager_secret.JWT.id
}

resource "aws_lambda_function" "aws_lambda_authorizer" {
  function_name = join("-", [var.app_name, "authorizer"])
  handler       = "auth.lambda_handler"
  runtime       = "python3.9"

  role        = aws_iam_role.lambda_role_authorizer.arn
  memory_size = 128
  timeout     = 5

  depends_on       = [null_resource.pkg_python_dependencies]
  source_code_hash = data.archive_file.lambda_zip_pkg["authorizer"].output_base64sha256
  filename         = data.archive_file.lambda_zip_pkg["authorizer"].output_path

  environment {
    variables = {
      JWT = jsondecode(data.aws_secretsmanager_secret_version.JWTSecret.secret_string)["token"]
    }
  }
}

resource "aws_lambda_function" "aws_lambda_reader" {
  function_name = join("-", [var.app_name, "reader"])
  handler       = "reader.lambda_handler"
  runtime       = "python3.9"

  role        = aws_iam_role.lambda_role_reader.arn
  memory_size = 128
  timeout     = 5

  depends_on       = [null_resource.pkg_python_dependencies]
  source_code_hash = data.archive_file.lambda_zip_pkg["reader"].output_base64sha256
  filename         = data.archive_file.lambda_zip_pkg["reader"].output_path

  environment {
    variables = {
      TABLE_NAME = var.db_name
    }
  }
}

resource "aws_lambda_function" "aws_lambda_writer" {
  function_name = join("-", [var.app_name, "writer"])
  handler       = "writer.lambda_handler"
  runtime       = "python3.9"

  role        = aws_iam_role.lambda_role_writer.arn
  memory_size = 128
  timeout     = 5

  depends_on       = [null_resource.pkg_python_dependencies]
  source_code_hash = data.archive_file.lambda_zip_pkg["writer"].output_base64sha256
  filename         = data.archive_file.lambda_zip_pkg["writer"].output_path

  environment {
    variables = {
      TABLE_NAME = var.db_name
    }
  }
}

resource "aws_api_gateway_rest_api" "app" {
  name = join("-", [var.app_name, "new"])
}

resource "aws_api_gateway_resource" "writer" {
  rest_api_id = aws_api_gateway_rest_api.app.id
  parent_id   = aws_api_gateway_rest_api.app.root_resource_id
  path_part   = "log"
}

resource "aws_api_gateway_method" "writer" {
  rest_api_id   = aws_api_gateway_rest_api.app.id
  resource_id   = aws_api_gateway_resource.writer.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.authorizer.id
}

resource "aws_api_gateway_resource" "reader" {
  rest_api_id = aws_api_gateway_rest_api.app.id
  parent_id   = aws_api_gateway_rest_api.app.root_resource_id
  path_part   = "stats"
}

resource "aws_api_gateway_method" "reader" {
  rest_api_id   = aws_api_gateway_rest_api.app.id
  resource_id   = aws_api_gateway_resource.reader.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.authorizer.id
}

resource "aws_api_gateway_authorizer" "authorizer" {
  name                             = "authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.app.id
  authorizer_uri                   = aws_lambda_function.aws_lambda_authorizer.invoke_arn
  authorizer_result_ttl_in_seconds = 0
  type                             = "REQUEST"
  identity_source                  = "method.request.header.jwt"
}

resource "aws_api_gateway_integration" "reader" {
  rest_api_id = aws_api_gateway_rest_api.app.id
  resource_id = aws_api_gateway_resource.reader.id
  http_method = aws_api_gateway_method.reader.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.aws_lambda_reader.invoke_arn
}

resource "aws_api_gateway_integration" "writer" {
  rest_api_id = aws_api_gateway_rest_api.app.id
  resource_id = aws_api_gateway_resource.writer.id
  http_method = aws_api_gateway_method.writer.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.aws_lambda_writer.invoke_arn
}
resource "aws_lambda_permission" "apigw-reader" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_lambda_reader.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.app.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw-writer" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_lambda_writer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.app.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw-authorizer" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_lambda_authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.app.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "app" {
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.reader.id,
      aws_api_gateway_method.reader.id,
      aws_api_gateway_integration.reader.id,
      aws_api_gateway_resource.writer.id,
      aws_api_gateway_method.writer.id,
      aws_api_gateway_integration.writer.id,
      aws_api_gateway_rest_api.app.body
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
  rest_api_id = aws_api_gateway_rest_api.app.id
}
resource "aws_api_gateway_stage" "Prod" {
  deployment_id = aws_api_gateway_deployment.app.id
  rest_api_id   = aws_api_gateway_rest_api.app.id
  stage_name    = "Prod"
}

resource "aws_cloudfront_distribution" "app" {
  price_class     = "PriceClass_100"
  enabled         = true
  is_ipv6_enabled = false

  web_acl_id = aws_wafv2_web_acl.WebACLWithTorBlock.arn
  origin {
    domain_name = "${aws_api_gateway_rest_api.app.id}.execute-api.us-west-2.amazonaws.com"
    origin_path = "/Prod"
    origin_id   = "MyOrigin"

    custom_header {
      name  = "jwt"
      value = jsondecode(data.aws_secretsmanager_secret_version.JWTSecret.secret_string)["token"]
    }
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }


  default_cache_behavior {
    allowed_methods = [
      "GET",
      "POST",
      "HEAD",
      "DELETE",
      "OPTIONS",
      "PUT",
      "PATCH"
    ]
    cached_methods         = ["HEAD", "GET"]
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
    target_origin_id       = "MyOrigin"
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" #Managed cache policy - CachingDisabled
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_wafv2_web_acl" "WebACLWithTorBlock" {
  provider = aws.virginia
  name     = join("-", [var.app_name, "WebACLWithTorBlock"])
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesAnonymousIpList"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAnonymousIpList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "MetricForWebACLWithManagedIPReputation"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "MetricForWebACLWithTorBlock"
    sampled_requests_enabled   = true
  }
}
