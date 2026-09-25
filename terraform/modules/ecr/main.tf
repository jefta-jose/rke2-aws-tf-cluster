# Mirrors rok-scaleout ecr_collection/ecr.
resource "aws_ecr_repository" "repo" {
  name                 = "amarok-therok-${var.ecr_url}"
  image_tag_mutability = "MUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = false
  }
}
