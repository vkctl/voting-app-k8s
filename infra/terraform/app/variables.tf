variable "worker_image_tag" {
    description = "Image tag for the worker service - passed in at apply time, e.g. from CI"
    type = string
    default = "dev-latest"
}

variable "vote_image_tag" {
    description = "Image tag for the vote service"
    type = string
    default = "dev-latest"
}

variable "result_image_tag" {
    description = "Image tag for the result service"
    type = string
    default = "dev-latest"
}

variable "image_owner" {
    description = "GHCR username that owns the images"
    type = string
    default = "vkctl"
}