"""Official reader/judge templates; the LoCoMo judge is MyClip's additional metric.

Provenance and scoring rules: ../docs/memory-benchmark-protocol.md.
"""

CATEGORY_NUMBERS = {"multi-hop": 1, "temporal": 2, "open-domain": 3, "single-hop": 4, "adversarial": 5}

LOCOMO_HEADER = ("Below are excerpts from conversations between two people, {} and {}. The conversations take place over "
                 "multiple days and the date of each conversation is written at the beginning of each excerpt.\n\n")
LOCOMO_QA = ("\nBased on the above context, write an answer in the form of a short phrase for the following question. "
             "Answer with exact words from the context whenever possible.\n\nQuestion: {} Short answer:\n")
LOCOMO_QA_CAT5 = ("\nBased on the above context, answer the following question. If the information is not available in the "
                  "context, answer 'No information available'.\n\nQuestion: {} Short answer:\n")
LOCOMO_TEMPORAL_SUFFIX = " Use DATE of CONVERSATION to answer with an approximate date."
LOCOMO_JUDGE = ("I will give you a question, a correct answer, and a response from a model. Please answer yes if the response "
                "contains the correct answer or is semantically equivalent to it. Minor wording differences, extra context, or "
                "approximate dates within the same week are fine. If the response contradicts the correct answer or only contains "
                "part of the information required, answer no.\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n"
                "Is the model response correct? Answer yes or no only.")

LME_READER = ("I will give you several history chats between you and a user. Please answer the question based on the relevant "
              "chat history.\n\n\nHistory Chats:\n\n{}\n\nCurrent Date: {}\nQuestion: {}\nAnswer:")
LME_JUDGE_DEFAULT = ("I will give you a question, a correct answer, and a response from a model. Please answer yes if the response "
                     "contains the correct answer. Otherwise, answer no. If the response is equivalent to the correct answer or "
                     "contains all the intermediate steps to get the correct answer, you should also answer yes. If the response "
                     "only contains a subset of the information required by the answer, answer no. \n\nQuestion: {}\n\nCorrect "
                     "Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only.")
LME_JUDGE = {
    "single-session-user": LME_JUDGE_DEFAULT, "single-session-assistant": LME_JUDGE_DEFAULT, "multi-session": LME_JUDGE_DEFAULT,
    "temporal-reasoning": LME_JUDGE_DEFAULT.replace(
        "answer no. \n\nQuestion",
        "answer no. In addition, do not penalize off-by-one errors for the number of days. If the question asks for the number of "
        "days/weeks/months, etc., and the model makes off-by-one errors (e.g., predicting 19 days when the answer is 18), the "
        "model's response is still correct. \n\nQuestion"),
    "knowledge-update": ("I will give you a question, a correct answer, and a response from a model. Please answer yes if the response "
                         "contains the correct answer. Otherwise, answer no. If the response contains some previous information along "
                         "with an updated answer, the response should be considered as correct as long as the updated answer is the "
                         "required answer.\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response "
                         "correct? Answer yes or no only."),
    "single-session-preference": ("I will give you a question, a rubric for desired personalized response, and a response from a "
                                  "model. Please answer yes if the response satisfies the desired response. Otherwise, answer no. The "
                                  "model does not need to reflect all the points in the rubric. The response is correct as long as it "
                                  "recalls and utilizes the user's personal information correctly.\n\nQuestion: {}\n\nRubric: {}\n\n"
                                  "Model Response: {}\n\nIs the model response correct? Answer yes or no only."),
}
LME_JUDGE_ABSTENTION = ("I will give you an unanswerable question, an explanation, and a response from a model. Please answer yes if "
                        "the model correctly identifies the question as unanswerable. The model could say that the information is "
                        "incomplete, or some other information is given but the asked information is not.\n\nQuestion: {}\n\n"
                        "Explanation: {}\n\nModel Response: {}\n\nDoes the model correctly identify the question as unanswerable? "
                        "Answer yes or no only.")


def reader_prompt(dataset, question, context, speakers=None):
    if dataset == "locomo":
        category = CATEGORY_NUMBERS[question["category"]]
        text = question["question"] + (LOCOMO_TEMPORAL_SUFFIX if category == 2 else "")
        return LOCOMO_HEADER.format(*speakers) + context + (LOCOMO_QA_CAT5 if category == 5 else LOCOMO_QA).format(text)
    return LME_READER.format(context, question.get("question_date") or "unknown", question["question"])


def judge_prompt(dataset, question, response):
    if dataset == "locomo":
        return LOCOMO_JUDGE.format(question["question"], question["answer"], response)
    if question["id"].endswith("_abs"):
        return LME_JUDGE_ABSTENTION.format(question["question"], question["answer"], response)
    return LME_JUDGE[question["category"]].format(question["question"], question["answer"], response)
