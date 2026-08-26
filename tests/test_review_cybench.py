from __future__ import annotations

import copy
import unittest

from scripts import review_cybench as review


def complete_contract(
    *,
    policy: str = "baseline-v1",
    pipeline_version: int = 3,
) -> dict[str, object]:
    return review.comparability_contract(
        {
            "agent_policy_version": policy,
            "agent_prompt_sha256": "0" * 64,
            "agent_toolchain_id": "upstream-static-v1",
            "agent_toolchain_image_digest": "sha256:" + "1" * 64,
            "agent_toolchain_manifest_sha256": "2" * 64,
            "documentation_pipeline_id": "iterative-active-window",
            "documentation_pipeline_version": pipeline_version,
        }
    )


def aggregate_result(
    contract: dict[str, object],
    *,
    correct: bool,
    score: int,
) -> dict[str, object]:
    return {
        "selection": {"scored": True},
        "validity": "valid",
        "official": {"correct": correct},
        "final_score": score,
        "informative_failure": False,
        "comparability_contract": contract,
    }


class ComparabilityContractTests(unittest.TestCase):
    def test_contract_captures_every_required_field_and_is_manifest_bound(self) -> None:
        contract = complete_contract()

        self.assertTrue(contract["complete"])
        self.assertEqual(contract["missing_fields"], [])
        self.assertEqual(
            set(contract["fields"]),
            set(review.COMPARABILITY_FIELDS),
        )
        self.assertEqual(
            review.validate_comparability_contract(contract),
            contract,
        )

        packet = {
            "schema_version": "1.1",
            "review_evaluator_version": "1.1",
            "rubric_sha256": "a" * 64,
            "profiles_sha256": "b" * 64,
            "assessment_schema_sha256": "c" * 64,
            "comparability_contracts": [contract],
            "logs": [{"comparability_contract": contract}],
            "samples": [
                {
                    "result_key": "result-1",
                    "immutable_payload_sha256": "d" * 64,
                    "comparability_contract": contract,
                }
            ],
        }
        manifest = review.packet_manifest_payload(packet)

        self.assertEqual(manifest["comparability_contracts"], [contract])
        self.assertEqual(
            manifest["samples"][0]["comparability_contract_key"],
            contract["contract_key"],
        )
        self.assertEqual(
            manifest["logs"][0]["comparability_contract"],
            contract,
        )

    def test_incomplete_and_tampered_contracts_fail_closed(self) -> None:
        incomplete = review.comparability_contract(
            {"agent_policy_version": "baseline-v1"}
        )
        self.assertFalse(incomplete["complete"])
        self.assertIn(
            "agent_toolchain_id",
            incomplete["missing_fields"],
        )

        tampered = copy.deepcopy(complete_contract())
        tampered["fields"]["agent_policy_version"] = "efficient-v2"
        with self.assertRaisesRegex(SystemExit, "key or completeness"):
            review.validate_comparability_contract(tampered)


class ContractSeparatedAggregateTests(unittest.TestCase):
    def test_single_complete_contract_emits_metrics(self) -> None:
        contract = complete_contract()
        aggregate = review.build_aggregate(
            [
                aggregate_result(contract, correct=True, score=80),
                aggregate_result(contract, correct=False, score=60),
            ]
        )

        self.assertEqual(
            aggregate["aggregation_status"],
            "single_comparable_contract",
        )
        self.assertTrue(aggregate["cross_contract_aggregate_permitted"])
        self.assertEqual(aggregate["contract_group_count"], 1)
        self.assertEqual(aggregate["official_success_rate_clean"], 0.5)
        self.assertEqual(
            aggregate["mean_documentation_process_score_clean"],
            70,
        )

    def test_mixed_contracts_never_emit_a_blended_metric(self) -> None:
        baseline = complete_contract(policy="baseline-v1")
        efficient = complete_contract(policy="efficient-v2")
        neutral = complete_contract(policy="neutral-v1")
        aggregate = review.build_aggregate(
            [
                aggregate_result(baseline, correct=True, score=80),
                aggregate_result(efficient, correct=False, score=60),
                aggregate_result(neutral, correct=True, score=70),
            ]
        )

        self.assertEqual(
            aggregate["aggregation_status"],
            "separated_by_contract",
        )
        self.assertFalse(aggregate["cross_contract_aggregate_permitted"])
        self.assertEqual(aggregate["contract_group_count"], 3)
        self.assertIsNone(aggregate["official_success_rate_clean"])
        self.assertIsNone(
            aggregate["mean_documentation_process_score_clean"]
        )

        groups = {
            group["contract_key"]: group
            for group in aggregate["contract_groups"]
        }
        self.assertEqual(
            groups[baseline["contract_key"]]["aggregate"][
                "official_success_rate_clean"
            ],
            1.0,
        )
        self.assertEqual(
            groups[efficient["contract_key"]]["aggregate"][
                "official_success_rate_clean"
            ],
            0.0,
        )
        self.assertEqual(
            groups[neutral["contract_key"]]["aggregate"][
                "official_success_rate_clean"
            ],
            1.0,
        )

    def test_incomplete_contract_keeps_counts_but_suppresses_metrics(self) -> None:
        incomplete = review.comparability_contract(
            {"agent_policy_version": "baseline-v1"}
        )
        aggregate = review.build_aggregate(
            [aggregate_result(incomplete, correct=True, score=95)]
        )

        self.assertEqual(aggregate["aggregation_status"], "contract_incomplete")
        self.assertFalse(aggregate["cross_contract_aggregate_permitted"])
        self.assertEqual(aggregate["selected_sample_count"], 1)
        self.assertEqual(aggregate["official_solved_count"], 1)
        self.assertIsNone(aggregate["official_success_rate_clean"])
        self.assertIsNone(
            aggregate["mean_documentation_process_score_clean"]
        )
        group_metrics = aggregate["contract_groups"][0]["aggregate"]
        self.assertIsNone(group_metrics["official_success_rate_clean"])
        self.assertIsNone(
            group_metrics["mean_documentation_process_score_clean"]
        )


if __name__ == "__main__":
    unittest.main()
