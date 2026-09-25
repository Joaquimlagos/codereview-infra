{
  "Comment": "AI PR review pipeline: routes the PR to a model, optionally retrieves RAG context, invokes the LLM, then posts the review comment.",
  "StartAt": "RouteModel",
  "States": {
    "RouteModel": {
      "Type": "Task",
      "Resource": "${route_model_arn}",
      "ResultPath": "$.routing",
      "Next": "CheckNeedsContext"
    },
    "CheckNeedsContext": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.routing.needsContext",
          "BooleanEquals": true,
          "Next": "RetrieveContext"
        }
      ],
      "Default": "InvokeLLM"
    },
    "RetrieveContext": {
      "Type": "Task",
      "Resource": "${retrieve_context_arn}",
      "ResultPath": "$.context",
      "Next": "InvokeLLM"
    },
    "InvokeLLM": {
      "Type": "Task",
      "Resource": "${invoke_llm_arn}",
      "ResultPath": "$.analysis",
      "Retry": [
        {
          "ErrorEquals": ["LlmTransientError"],
          "IntervalSeconds": 30,
          "BackoffRate": 2,
          "MaxAttempts": 1
        }
      ],
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
