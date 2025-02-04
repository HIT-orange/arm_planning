function [links, k_lim, k_unsafe_A, k_unsafe_b] = compute_unsafe_parameters(varargin)
%COMPUTE_UNSAFE_PARAMETERS generates constraints on trajectory
%   parameters given a set of obstacles.
%   COMPUTE_UNSAFE_PARAMETERS(x_0, x_dot_0, obstacles) uses
%   the initial configuration (vector x_0) and initial velocities
%   (x_dot_0) to construct an appropriate FRS of the arm over a range
%   of trajectory parameters. Then, it intersects the FRS with the
%   obstacles (cell of zonotopes) to generate constraints describing unsafe
%   trajectory paramters.
%
%   COMPUTE_UNSAFE_PARAMETERS(x_0, x_dot_0, obstacles, options) uses the
%   struct options to specify the position dimensions of the FRS, the IC
%   dimensions, and the parameter dimensions. Also specify the planning
%   time and stopping time.

switch nargin
    case 3
        x_0 = varargin{1};
        x_dot_0 = varargin{2};
        obstacles = varargin{3};
        options = struct();
        options.t_plan = 0.5;
        options.t_stop = 1;
        options.position_dimensions = [1;2]; % x and y dimensions
        options.IC_dimensions = [3]; % x_dot_0
        options.param_dimensions = [4]; % k dimensions
        options.nLinks = 2;
    case 4
        x_0 = varargin{1};
        x_dot_0 = varargin{2};
        obstacles = varargin{3};
        options = varargin{4};
    otherwise
        error('Specify x_0, x_dot_0, and obstacles');
end

links = stack_FRS(x_0, x_dot_0, options); % this also slices at the correct initial velocity
nLinks = length(links);
nObs = length(obstacles);

k_lim = cell(nLinks, 1);
k_unsafe_A = cell(nLinks, 1);
k_unsafe_b = cell(nLinks, 1);
for i = 1:nLinks
% for i = 2
    k_lim{i} = get_parameter_limits(links{i});
    k_unsafe_A{i} = cell(nObs, 1);
    k_unsafe_b{i} = cell(nObs, 1);
    for j = 1:nObs
        [k_unsafe_A{i}{j}, k_unsafe_b{i}{j}] = get_parameter_constraints(links{i}, k_lim{i}, obstacles{j}.zono);
        %%% MALICIOUS HACK DISCARD GROUND OBSTACLE FOR FIRST LINK
        if i == 1 && j == 1
            k_unsafe_A{i}{j} = [];
            k_unsafe_b{i}{j} = [];
        end
    end
end


end

