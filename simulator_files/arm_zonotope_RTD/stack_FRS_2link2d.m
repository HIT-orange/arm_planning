function [links] = stack_FRS_2link2d(theta_0, theta_dot_0)
%STACK_FRS given the initial configuration and velocities of a two link
%arm, generates the FRS of each link
% 2nd link FRS is generated by stacking two one link FRS's together
% theta_0 is 2x1 column vector containing theta_1, theta_2
% theta_dot_0 is 2x1 column vector containing theta_1_dot, theta_2_dot

load('FRS/0key')

A1 = [cos(theta_0(1)), -sin(theta_0(1)), 0, 0, 0; sin(theta_0(1)), cos(theta_0(1)), 0, 0, 0; 0 0 1 0 0; 0 0 0 1 0; 0 0 0 0 1];
A2 = [cos(theta_0(1)+theta_0(2)), -sin(theta_0(1)+theta_0(2)), 0, 0, 0; sin(theta_0(1)+theta_0(2)), cos(theta_0(1)+theta_0(2)), 0, 0, 0; 0 0 1 0 0; 0 0 0 1 0; 0 0 0 0 1];

[~, closest_idx_1] = min(abs(theta_dot_0(1) - c_theta_dot_0));
filename1 = sprintf('FRS/arm_FRS_%0.3f.mat', c_theta_dot_0(closest_idx_1));

[~, closest_idx_2] = min(abs((theta_dot_0(1) + theta_dot_0(2)) - c_theta_dot_0));
filename2 = sprintf('FRS/arm_FRS_%0.3f.mat', c_theta_dot_0(closest_idx_2));

file1 = load(filename1);
file2 = load(filename2);

Rcont1 = file1.Rcont;
Rcont1EE = file1.RcontEE;
Rcont2 = file2.Rcont;

links = cell(2, 1);
% tic;
% rotate and stack Rcont to get FRSs of links
for i = 1:length(Rcont1)
%     Z1 = get(Rcont1{i}{1}, 'Z');
%     Z1EE = get(Rcont1EE{i}{1}, 'Z');
%     Z2 = get(Rcont2{i}{1}, 'Z');
    
    Z1 = zonotope_slice(Rcont1{i}{1}, 3, theta_dot_0(1));
    Z1EE = zonotope_slice(Rcont1EE{i}{1}, 3, theta_dot_0(1));
    Z2 = zonotope_slice(Rcont2{i}{1}, 3, (theta_dot_0(1) + theta_dot_0(2)));
    
    Z1 = get(Z1, 'Z');
    Z1EE = get(Z1EE, 'Z');
    Z2 = get(Z2, 'Z');

    Z1 = A1*Z1;
    Z1EE = A1*Z1EE;
    Z2 = A2*Z2;
    
    % remove angular velocity row of Z cuz we've sliced it
    Z1(3, :) = [];
    Z1EE(3, :) = [];
    Z2(3, :) = [];
    
    %%% MALICIOUS HACK RAISE THE FRS's BY 0.055 TO GET OFF THE GROUND
%     Z1(:, 1) = Z1(:, 1) + [0; 0.050; 0; 0];
%     Z2(:, 1) = Z2(:, 1) + [0; 0.050; 0; 0];
    
    mytimestep = file1.options.timeStep;
    myzeros = zeros(1, size(Z1EE, 2) - 1);
    
    newZ1 = [[Z1(1:3, 1); Z1(4, 1)], [0;0;0;mytimestep], [Z1(1:3, 2:end); myzeros]];
    newZ2 = [[Z1EE(1:2, 1) + Z2(1:2, 1); Z1EE(3, 1); Z2(3, 1); Z1EE(4, 1)], [0;0;0;0;mytimestep], [Z1EE(1:3, 2:end); myzeros; myzeros], [Z2(1:2, 2:end); myzeros; Z2(3, 2:end); myzeros]];
    
    links{1}.FRS{i} = zonotope(newZ1);
    links{2}.FRS{i} = zonotope(newZ2);
end
% disp('Computation time of FRS 2Link generation');
% toc;

links{1}.info.labels = {'X-position'; 'Y-position'; 'k1 (peak theta_1_dot)'; 'time'};
links{1}.info.position_dimensions = [1; 2];
links{1}.info.param_dimensions = [3];
links{1}.info.max_params = 2;
links{2}.info.labels = {'X-position'; 'Y-position'; 'k1 (peak theta_1_dot)'; 'k2 (peak (theta_1_dot + theta_2_dot) )'; 'time'};
links{2}.info.position_dimensions = [1; 2];
links{2}.info.param_dimensions = [3; 4];
links{2}.info.max_params = 2;

end