'use strict';

// CLI test stand-in for config.uc: the model is whatever suite.uc wrote to model.json.

import { readfile } from 'fs';

export function load() {
	return json(readfile('/tmp/shv-routing-cli/model.json') ?? '{}');
};
