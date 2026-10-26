'use strict';

// Routing area: validate.uc, lists.uc, routing.uc and the lists CLI. The cases live in
// tests/unit/routing/suite.uc; it is started with the fixture stubs after the package tree on the module
// path, so a module another area has not written yet (const.uc) still resolves.

import { dirname } from 'fs';

const here = dirname(sourcepath());
const src = `${here}/../../shadow-vpn/files/usr/share/ucode`;

exit(system(sprintf("exec ucode -L '%s' -L '%s/routing/stubs' '%s/routing/suite.uc' '%s/../..'",
	src, here, here, here)));
