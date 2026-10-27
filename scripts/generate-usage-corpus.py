import argparse
import datetime
import json
import os
import random

parser = argparse.ArgumentParser()
parser.add_argument("output")
parser.add_argument("--files", type=int, default=24)
parser.add_argument("--records", type=int, default=5000)
parser.add_argument("--seed", type=int, default=7)
arguments = parser.parse_args()
random.seed(arguments.seed)
base = datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc)
models = ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]
for index in range(arguments.files):
    project = "/synthetic/project-%02d" % (index % 6)
    directory = os.path.join(arguments.output, ".claude", "projects", "-synthetic-%02d" % index)
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "session-%03d.jsonl" % index), "w") as handle:
        for line in range(arguments.records):
            moment = base + datetime.timedelta(
                hours=random.randint(0, 24 * 28), minutes=random.randint(0, 59))
            number = line if line % 50 else max(line - 1, 0)
            record = {
                "timestamp": moment.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                "sessionId": "session-%03d" % index,
                "requestId": "request-%d-%d" % (index, number),
                "cwd": project,
                "message": {
                    "id": "message-%d-%d" % (index, number),
                    "model": random.choice(models),
                    "usage": {
                        "input_tokens": random.randint(10, 2000),
                        "output_tokens": random.randint(10, 900),
                        "cache_read_input_tokens": random.randint(0, 5000),
                        "cache_creation_input_tokens": random.randint(0, 800),
                    },
                },
            }
            handle.write(json.dumps(record) + "\n")
