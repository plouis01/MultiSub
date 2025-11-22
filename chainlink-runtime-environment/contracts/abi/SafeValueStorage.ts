export const SafeValueStorage = [
	{
		type: 'constructor',
		inputs: [{ name: '_authorizedUpdater', type: 'address', internalType: 'address' }],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'authorizedUpdater',
		inputs: [],
		outputs: [{ name: '', type: 'address', internalType: 'address' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'getSafeValue',
		inputs: [{ name: 'safeAddress', type: 'address', internalType: 'address' }],
		outputs: [
			{ name: 'totalValueUSD', type: 'uint256', internalType: 'uint256' },
			{ name: 'lastUpdated', type: 'uint256', internalType: 'uint256' },
			{ name: 'updateCount', type: 'uint256', internalType: 'uint256' },
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'isValueStale',
		inputs: [
			{ name: 'safeAddress', type: 'address', internalType: 'address' },
			{ name: 'maxAge', type: 'uint256', internalType: 'uint256' },
		],
		outputs: [{ name: 'isStale', type: 'bool', internalType: 'bool' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'owner',
		inputs: [],
		outputs: [{ name: '', type: 'address', internalType: 'address' }],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'safeValues',
		inputs: [{ name: '', type: 'address', internalType: 'address' }],
		outputs: [
			{ name: 'totalValueUSD', type: 'uint256', internalType: 'uint256' },
			{ name: 'lastUpdated', type: 'uint256', internalType: 'uint256' },
			{ name: 'updateCount', type: 'uint256', internalType: 'uint256' },
		],
		stateMutability: 'view',
	},
	{
		type: 'function',
		name: 'setAuthorizedUpdater',
		inputs: [{ name: 'newUpdater', type: 'address', internalType: 'address' }],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'transferOwnership',
		inputs: [{ name: 'newOwner', type: 'address', internalType: 'address' }],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'function',
		name: 'updateSafeValue',
		inputs: [
			{ name: 'safeAddress', type: 'address', internalType: 'address' },
			{ name: 'totalValueUSD', type: 'uint256', internalType: 'uint256' },
		],
		outputs: [],
		stateMutability: 'nonpayable',
	},
	{
		type: 'event',
		name: 'AuthorizedUpdaterChanged',
		inputs: [
			{ name: 'oldUpdater', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'newUpdater', type: 'address', indexed: true, internalType: 'address' },
		],
		anonymous: false,
	},
	{
		type: 'event',
		name: 'SafeValueUpdated',
		inputs: [
			{ name: 'safeAddress', type: 'address', indexed: true, internalType: 'address' },
			{ name: 'totalValueUSD', type: 'uint256', indexed: false, internalType: 'uint256' },
			{ name: 'timestamp', type: 'uint256', indexed: false, internalType: 'uint256' },
			{ name: 'updateCount', type: 'uint256', indexed: false, internalType: 'uint256' },
		],
		anonymous: false,
	},
] as const
