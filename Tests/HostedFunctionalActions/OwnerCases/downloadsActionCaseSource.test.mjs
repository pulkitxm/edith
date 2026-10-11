import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { definition } from '../../../scripts/hosted-functional-actions/cases/downloads.mjs';

test('download readback uses the production worker command and real retained files', async () => {
  const worker = await readFile(new URL('../../../Extensions/downloads/Worker.swift', import.meta.url), 'utf8');
  const client = await readFile(new URL('../../../Extensions/downloads/Services/DownloadsClient.swift', import.meta.url), 'utf8');
  const source = await readFile(new URL('./downloadsActionCase.swift', import.meta.url), 'utf8');
  assert(definition.operations.includes('downloads.snapshot'));
  assert(worker.includes('case "downloads.snapshot":'));
  assert(client.includes('client.invoke("downloads.snapshot")'));
  assert(source.includes('transport.readAuthoritative("downloads.snapshot")'));
  assert(source.includes('DownloadQueue.read(from: history)'));
  assert(source.includes('history.appendingPathExtension("activity.json")'));
  assert(source.includes('encoder.encode(records) == encoder.encode(snapshot.records)'));
});
