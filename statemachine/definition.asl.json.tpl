{
  "Comment": "Esqueleto do pipeline de revisao de PR com IA (estados dummy, sem logica de negocio).",
  "StartAt": "RouteModel",
  "States": {
    "RouteModel": {
      "Type": "Task",
      "Resource": "${route_model_arn}",
      "ResultPath": "$.routeModel",
      "Next": "NeedsRag"
    },
    "NeedsRag": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.routeModel.needsRag",
          "BooleanEquals": true,
          "Next": "RetrieveContext"
        }
      ],
      "Default": "InvokeLLM"
    },
    "RetrieveContext": {
      "Type": "Task",
      "Resource": "${retrieve_context_arn}",
      "ResultPath": "$.retrieveContext",
      "Next": "InvokeLLM"
    },
    "InvokeLLM": {
      "Type": "Task",
      "Resource": "${invoke_llm_arn}",
      "ResultPath": "$.invokeLlm",
      "Next": "PostComment"
    },
    "PostComment": {
      "Type": "Task",
      "Resource": "${post_comment_arn}",
      "ResultPath": "$.postComment",
      "End": true
    }
  }
}
