classdef robot_arm_rotatotope_RTD_planner_3D_fetch < robot_arm_generic_planner
    %% properties
    properties
        trajopt_start_tic
        t_total = 1 ; % total duration of desired traj
        time_discretization = 0.01 ; % time discretization of desired traj
        FRS_options struct;
        
        % for current FRS
        R ;
        
        % from previous time step
        Z_prev = [];
        R_prev ;
        q_0_prev = [];
        q_dot_0_prev = [];
        k_opt_prev = [];
        
        iter = 0;
        first_iter_pause_flag = true ;
       
    end
    
    %% methods
    methods
        %% constructor
        function P = robot_arm_rotatotope_RTD_planner_3D_fetch(varargin)
            t_move = 0.5;
            lookahead_distance = 0.3;
%             lookahead_distance = 1;
%             HLP = robot_arm_RRT_HLP('make_new_tree_every_iteration_flag',true) ;
%             HLP = robot_arm_PRM_HLP( ) ;
            HLP = robot_arm_straight_line_HLP( );
            P@robot_arm_generic_planner('lookahead_distance', lookahead_distance, 't_move', t_move, 'HLP', HLP, ...
                varargin{2:end}) ;
            P.FRS_options = varargin{1};
%             P.FRS_options.combs = generate_combinations_upto(200);
%             P.FRS_options.maxcombs = 200;
        end
        
        %% replan
        function [T,U,Z] = replan(P,agent_info,world_info)
            P.vdisp('Replanning!',5)
            
            P.vdisp('Seting joint state and speed limits',7)
            % set any joint limits that are +Inf to 200pi and -Inf to -200pi
            joint_limit_infs = isinf(P.arm_joint_state_limits) ;
            P.arm_joint_state_limits(1,joint_limit_infs(1,:)) = -200*pi ;
            P.arm_joint_state_limits(2,joint_limit_infs(2,:)) = +200*pi ;
            
            speed_limit_infs = isinf(P.arm_joint_speed_limits) ;
            P.arm_joint_speed_limits(1,speed_limit_infs(1,:)) = -200*pi ;
            P.arm_joint_speed_limits(2,speed_limit_infs(2,:)) = +200*pi ;
            
            P.vdisp('Generating cost function',6)
            % generate a waypoint in configuration space
            if P.first_iter_pause_flag && P.iter == 0
               pause; 
            end
            P.iter = P.iter + 1;
            planning_time = tic;

            q_des = P.HLP.get_waypoint(agent_info,world_info,P.lookahead_distance) ;
            
            if isempty(q_des)
                P.vdisp('Waypoint creation failed! Using global goal instead.',3)
                q_des = P.HLP.goal ;
            end
                        
            P.vdisp('Generating constraints',6)
            % get current obstacles
            O = world_info.obstacles ;
            
            % get current state of robot
            q_0 = agent_info.state(P.arm_joint_state_indices, end) ;
            q_dot_0 = agent_info.state(P.arm_joint_speed_indices, end) ;
            
            % generate FRS
            P.R = robot_arm_FRS_rotatotope_fetch(q_0, q_dot_0, P.FRS_options);
            
            % map obstacles to trajectory parameter space
            P.R = P.R.generate_constraints(O);
            
            % protect against self-intersections:
%             P.R = P.R.generate_self_intersection_constraints;
%             [~, k_lim, k_unsafe_A, k_unsafe_b] = compute_unsafe_parameters_3D(P.R, P.phi_dot_0, O, P.FRS_options);
            
            P.vdisp('Replan is calling trajopt!',8)
            try
                [k_opt, trajopt_failed] = P.trajopt(q_0, q_dot_0, q_des);
            catch
                trajopt_failed = true ;
            end
%             disp(k_opt);
%             pause;
            
            P.vdisp('Processing trajopt result',8)
            if ~trajopt_failed
                P.vdisp('New trajectory found!',3);
                
                [T, U, Z] = P.generate_trajectory(q_0, q_dot_0, k_opt);
                
                toc(planning_time);
             
                P.R_prev = P.R;
                P.Z_prev = Z;
                
                P.q_0_prev = q_0;
                P.q_dot_0_prev = q_dot_0;
                P.k_opt_prev = k_opt;
            else % if no safe trajectory parameter found:
                % generate a braking trajectory
                P.vdisp('Unable to find new trajectory!',3)
                T = 0:P.time_discretization:P.t_total ;
                T_plan = T(1:floor(length(T)/2));
                %                 T_brake = T(floor(length(T)/2)+1:end);
                N_T = length(T) ;
                U = zeros(P.arm_n_inputs,N_T) ;
                if ~isnan(P.q_0_prev) % if prev trajectory was not a braking traj
                    %                     Z = P.generate_trajectory(T, P.q_0_prev, P.q_dot_0_prev, P.k_opt_prev);
                    %                     Z_brake = Z(:, floor(length(T)/2)+1:end);
                    Z_brake = P.Z_prev(:, floor(length(T)/2)+1:end);
                    z = [Z_brake(1:2:end, end)'; zeros(length(q_0), 1)'];
                    Z = [Z_brake, ones(size(Z_brake, 1), length(T_plan)).*z(:)];
                    P.q_0_prev = nan;
                    P.q_dot_0_prev = nan;
                    P.k_opt_prev = nan;
                else
                    % command to stay in place
                    z = [q_0'; zeros(length(q_0), 1)'];
                    Z = ones(length(q_0) + length(q_dot_0), length(T)).*z(:);
                    P.q_0_prev = nan;
                    P.q_dot_0_prev = nan;
                    P.k_opt_prev = nan;
                end
                toc(planning_time);
            end
            %             toc;
        end
        
        function [k_opt, trajopt_failed] = trajopt(P, q_0, q_dot_0, q_des)
            % use fmincon to optimize the cost subject to constraints
            P.vdisp('Running trajopt',3)
            
            P.trajopt_start_tic = tic ;
            
            cost_func = @(k) P.eval_cost(k, q_0, q_dot_0, q_des);
            constraint_func = @(k) P.eval_constraint(k, q_0, q_dot_0);
            
            % generate upper and lower bounds
            lb = P.R.c_k - P.R.g_k;
            ub = P.R.c_k + P.R.g_k;
            
            initial_guess = (lb + ub)/2;
           
%             options = optimoptions('fmincon','SpecifyConstraintGradient',true, 'Algorithm', 'interior-point');
            options = optimoptions('fmincon','SpecifyConstraintGradient',true);
%             options = optimoptions('fmincon');
            [k_opt, ~, exitflag, ~] = fmincon(cost_func, initial_guess, [], [], [], [], lb, ub, constraint_func, options) ;
            
            trajopt_failed = exitflag <= 0 ;
        end
        
        function [cost] = eval_cost(P, k, q_0, q_dot_0, q_des)
            % generate a simple cost function
           q_plan = compute_q_plan(P, q_0, q_dot_0, k);
           cost = sum((q_plan - q_des).^2);
           
           error_if_out_of_time(P.trajopt_start_tic,P.t_plan)
        end
        
        function [c, ceq, gradc, gradceq] = eval_constraint(P, k_opt, q_0, q_dot_0)
            epsilon = 1e-3;
            ceq = [];
            gradceq = [];
            
            c = [];
            gradc = [];
            %%% Joint limit constraints:
            [q_min, q_max, q_dot_min, q_dot_max, grad_q_min, grad_q_max, grad_q_dot_min, grad_q_dot_max] = P.compute_max_min_states(q_0, q_dot_0, k_opt);
            c_joint = [];
            c_joint = [c_joint; P.arm_joint_state_limits(1, :)' - q_min];
            c_joint = [c_joint; -P.arm_joint_state_limits(2, :)' + q_max];
            c_joint = [c_joint; P.arm_joint_speed_limits(1, :)' - q_dot_min];
            c_joint = [c_joint; -P.arm_joint_speed_limits(2, :)' + q_dot_max];
            
            grad_c_joint = [grad_q_min, grad_q_max];
            grad_c_joint = [grad_q_min, grad_q_max, grad_q_dot_min, grad_q_dot_max];
            
            c = [c; c_joint];
            gradc = [gradc, grad_c_joint];
                        
            %%% Obstacle constraint generation:
            for i = 1:length(P.R.A_con) % for each obstacle
                for j = 1:length(P.R.A_con{i}) % for each link
                    idx = find(~cellfun('isempty', P.R.A_con{i}{j}));
                    k_param = k_opt(P.R.link_joints{j});
                    c_param = P.R.c_k(P.R.link_joints{j});
                    g_param = P.R.g_k(P.R.link_joints{j});
%                     lambda = c_param + (k_param./g_param);
                    lambda = (k_param - c_param)./g_param;
                    for k = 1:length(idx) % for each time step
                        lambdas_prod = P.R.k_con{i}{j}{idx(k)}.*lambda;
                        lambdas_prod(~P.R.k_con{i}{j}{idx(k)}) = 1;
                        lambdas_prod = prod(lambdas_prod, 1)';
                        
                        c_obs = P.R.A_con{i}{j}{idx(k)}*lambdas_prod - P.R.b_con{i}{j}{idx(k)};
                        c_obs_max = max(c_obs);
                        c_k = -(c_obs_max - epsilon);
                        c = [c; c_k];
                        
                        % specify gradients
                        % this is going to be really gross... but basically
                        % the gradient will depend on the row of A being
                        % multiplied by lambda, as well as which k's the
                        % lambdas depend on. 
                        if nargout > 2
                            maxidx = find(c_obs == c_obs_max);
                            k_con_temp = P.R.k_con{i}{j}{idx(k)}';
                            lambdas_grad = k_con_temp;
                            cols = 1:length(lambda);
                            for l = 1:length(lambda)
                                lambdas_grad_temp = k_con_temp(:, l);
                                lambdas_grad_temp = lambdas_grad_temp*lambda(l);
                                lambdas_grad_temp(~k_con_temp(:, l)) = 1;
                                lambdas_grad(:, cols ~= l) = lambdas_grad_temp.*lambdas_grad(:, cols ~= l);
                            end
                            if length(maxidx) > 1
%                                 disp('ahhh');
                                tempgradc = P.R.A_con{i}{j}{idx(k)}(maxidx, :)*lambdas_grad;
                                gradc = [gradc, [(-max(tempgradc)')./g_param; zeros(length(k_opt) - length(lambda), 1)]];
                            else
                                gradc = [gradc, [(-(P.R.A_con{i}{j}{idx(k)}(maxidx, :)*lambdas_grad)')./g_param; zeros(length(k_opt) - length(lambda), 1)]];
                            end
                        end
                    end
                end
                
                error_if_out_of_time(P.trajopt_start_tic,P.t_plan)
            end
            
            %%% Self-intersection constraint generation:
            for i = 1:length(P.R.A_con_self) % for each pair of joints that can intersect
                idx = find(~cellfun('isempty', P.R.A_con_self{i}));
                for j = 1:length(idx) % for each (nonempty) time step
                    k_param = k_opt;
                    c_param = P.R.c_k;
                    g_param = P.R.g_k;
                    
                    lambda = (k_param - c_param)./g_param;
                    
                    % dumb way to do this... want to multiply rows of lambdas
                    % together, replacing zeros with ones
                    lambdas_prod = P.R.k_con_self{i}{idx(j)}.*lambda;
                    lambdas_prod(~P.R.k_con_self{i}{idx(j)}) = 1;
                    lambdas_prod = prod(lambdas_prod, 1)';
                    
                    c_obs = P.R.A_con_self{i}{idx(j)}*lambdas_prod - P.R.b_con_self{i}{idx(j)};
                    c_obs_max = max(c_obs);
                    c_k = -(c_obs_max - epsilon);
                    c = [c; c_k];
                    
                    % specify gradients
                    % this is going to be really gross... but basically
                    % the gradient will depend on the row of A being
                    % multiplied by lambda, as well as which k's the
                    % lambdas depend on.
                    if nargout > 2
                        maxidx = find(c_obs == c_obs_max);
                        k_con_temp = P.R.k_con_self{i}{idx(j)}';
                        lambdas_grad = k_con_temp;
                        cols = 1:length(lambda);
                        for l = 1:length(lambda)
                            lambdas_grad_temp = k_con_temp(:, l);
                            lambdas_grad_temp = lambdas_grad_temp*lambda(l);
                            lambdas_grad_temp(~k_con_temp(:, l)) = 1;
                            lambdas_grad(:, cols ~= l) = lambdas_grad_temp.*lambdas_grad(:, cols ~= l);
                        end
                        if length(maxidx) > 1
                            %                                 disp('ahhh');
                            tempgradc = P.R.A_con_self{i}{idx(j)}(maxidx, :)*lambdas_grad;
                            gradc = [gradc, (-max(tempgradc)')./g_param];
                        else
                            gradc = [gradc, (-(P.R.A_con_self{i}{idx(j)}(maxidx, :)*lambdas_grad)')./g_param];
                        end
                    end
                    
                end
            end
                    
            
        end
        
        function [T, U, Z] = generate_trajectory(P, q_0, q_dot_0, k_opt)
            T = 0:P.time_discretization:P.t_total ;
            T_plan = T(1:floor(length(T)/2)+1) ;
            T_brake = T(floor(length(T)/2)+1:end) ;
            
            t_to_stop = T_brake(end) - T_brake(1);
            U = zeros(P.arm_n_inputs,length(T));
            
            q_to_peak = q_0 + q_dot_0.*T_plan + (1/2)*k_opt.*T_plan.^2;
            q_dot_to_peak = q_dot_0 + k_opt.*T_plan;
            
            q_peak = q_to_peak(:, end);
            q_dot_peak = q_dot_to_peak(:, end);
            
            T_brake = T_brake - T_brake(1);
            q_to_stop = q_peak + q_dot_peak.*T_brake + (1/2)*((0 - q_dot_peak)./t_to_stop).*T_brake.^2;
            q_dot_to_stop = q_dot_peak + ((0 - q_dot_peak)./t_to_stop).*T_brake;
            
            % remove overlap
            q_to_stop(:, 1) = [];
            q_dot_to_stop(:, 1) = [];
            
            Z = zeros(length(q_0)*2, length(T));
            for i = 1:size(q_to_peak, 1)
               Z(2*i-1:2*i, :) =  [q_to_peak(i, :), q_to_stop(i, :); q_dot_to_peak(i, :), q_dot_to_stop(i, :)];
            end
        end
        
        function [q_plan] = compute_q_plan(P, q_0, q_dot_0, k)
            % returns the configuration at t_move given initial state and
            % chosen acceleration k; note if P.t_plan = P.t_move then
            % real-time planning is enforced (more or less)
            
            q_plan = q_0 + q_dot_0*P.t_move + (1/2)*k*P.t_move^2;
        end
        
        function [q_min, q_max, q_dot_min, q_dot_max, grad_q_min, grad_q_max, grad_q_dot_min, grad_q_dot_max] = compute_max_min_states(P, q_0, q_dot_0, k)
            % updated 11/27/2019... this function turned out a lot longer
            % than i was expecting... i tried to write it without using
            % maxes and mins (mebbe it'll be easier in C++ that way) but
            % that just made a lot of if statements.
            
            % compute the max and min joint positions and velocities over
            % the time horizon, given k.
            n_angles = length(q_0);
            n_k = length(k);
            t_to_stop = P.t_total - P.t_move;
            
            q_peak = q_0 + q_dot_0*P.t_move + (1/2)*k*P.t_move^2;
            q_dot_peak = q_dot_0 + k*P.t_move;
            q_ddot_to_stop = ((0 - q_dot_peak)./t_to_stop);
            
            q_max = zeros(n_angles, 1);
            q_min = zeros(n_angles, 1);
            q_dot_max = zeros(n_angles, 1);
            q_dot_min = zeros(n_angles, 1);
            
            grad_q_max = zeros(n_angles, 1);
            grad_q_min = zeros(n_angles, 1);
            grad_q_dot_max = zeros(n_angles, 1);
            grad_q_dot_min = zeros(n_angles, 1);
            
            q_max_to_peak = zeros(n_angles, 1);
            q_min_to_peak = zeros(n_angles, 1);
            q_dot_max_to_peak = zeros(n_angles, 1);
            q_dot_min_to_peak = zeros(n_angles, 1);
            
            grad_q_max_to_peak = zeros(n_angles, 1);
            grad_q_min_to_peak = zeros(n_angles, 1);
            grad_q_dot_max_to_peak = zeros(n_angles, 1);
            grad_q_dot_min_to_peak = zeros(n_angles, 1);
            
            q_max_to_stop = zeros(n_angles, 1);
            q_min_to_stop = zeros(n_angles, 1);
            q_dot_max_to_stop = zeros(n_angles, 1);
            q_dot_min_to_stop = zeros(n_angles, 1);
            
            grad_q_max_to_stop = zeros(n_angles, 1);
            grad_q_min_to_stop = zeros(n_angles, 1);
            grad_q_dot_max_to_stop = zeros(n_angles, 1);
            grad_q_dot_min_to_stop = zeros(n_angles, 1);
            
            q_stop = q_peak + q_dot_peak.*t_to_stop + (1/2)*q_ddot_to_stop.*t_to_stop.^2;
            
            t_max_min_to_peak = -q_dot_0./k; % time of max or min for to peak dynamics
            for i = 1:n_angles
                % TO PEAK PART OF TRAJECTORY
                % order q endpoints
                if q_peak(i) >= q_0(i)
                    q_endpoints_ordered = [q_0(i); q_peak(i)];
                    grad_q_endpoints_ordered = [0; (1/2)*P.t_move^2];
                else
                    q_endpoints_ordered = [q_peak(i); q_0(i)];
                    grad_q_endpoints_ordered = [(1/2)*P.t_move^2; 0];
                end
                
                if t_max_min_to_peak(i) > 0 && t_max_min_to_peak(i) < P.t_move % this implies local max/min of q
                    if k(i) >= 0
                        q_min_to_peak(i) = q_0(i) + q_dot_0(i)*t_max_min_to_peak(i) + (1/2)*k(i)*t_max_min_to_peak(i)^2;
                        q_max_to_peak(i)  = q_endpoints_ordered(2);
                        grad_q_min_to_peak(i) = ((1/2)*q_dot_0(i)^2)/k(i)^2;
                        grad_q_max_to_peak(i) = grad_q_endpoints_ordered(2);
                    else
                        q_min_to_peak(i) = q_endpoints_ordered(1);
                        q_max_to_peak(i) = q_0(i) + q_dot_0(i)*t_max_min_to_peak(i) + (1/2)*k(i)*t_max_min_to_peak(i)^2;
                        grad_q_min_to_peak(i) = grad_q_endpoints_ordered(1);
                        grad_q_max_to_peak(i) = ((1/2)*q_dot_0(i)^2)/k(i)^2;
                    end
                else
                    q_min_to_peak(i) = q_endpoints_ordered(1);
                    q_max_to_peak(i) = q_endpoints_ordered(2);
                    
                    grad_q_min_to_peak(i) = grad_q_endpoints_ordered(1);
                    grad_q_max_to_peak(i) = grad_q_endpoints_ordered(2);
                end
                
                % max or min velocity must occur at endpoints
                if q_dot_peak(i) >= q_dot_0(i)
                    q_dot_min_to_peak(i) = q_dot_0(i);
                    q_dot_max_to_peak(i) = q_dot_peak(i);
                    
                    grad_q_dot_min_to_peak(i) = 0;
                    grad_q_dot_max_to_peak(i) = P.t_move;
                else
                    q_dot_min_to_peak(i) = q_dot_peak(i);
                    q_dot_max_to_peak(i) = q_dot_0(i);
                    
                    grad_q_dot_min_to_peak(i) = P.t_move;
                    grad_q_dot_max_to_peak(i) = 0;
                end
            
                % BRAKING PART OF TRAJECTORY
                % note that when braking, we have 0 velocity at P.t_total.
                % Therefore, max and min q and q_dot occur at the endpoints of
                % the braking times.
                if q_stop(i) >= q_peak(i)
                    q_min_to_stop(i) = q_peak(i);
                    q_max_to_stop(i) = q_stop(i);
                    
                    grad_q_min_to_stop(i) = (1/2)*P.t_move^2;
                    grad_q_max_to_stop(i) = (1/2)*P.t_move^2 + (1/2)*P.t_move*t_to_stop;
                else
                    q_min_to_stop(i) = q_stop(i);
                    q_max_to_stop(i) = q_peak(i);
                    
                    grad_q_min_to_stop(i) = (1/2)*P.t_move^2 + (1/2)*P.t_move*t_to_stop;
                    grad_q_max_to_stop(i) = (1/2)*P.t_move^2;
                end
                
                if q_dot_peak(i) >= 0
                    q_dot_min_to_stop(i) = 0;
                    q_dot_max_to_stop(i) = q_dot_peak(i);
                    
                    grad_q_dot_min_to_stop(i) = 0;
                    grad_q_dot_max_to_stop(i) = P.t_move;
                else
                    q_dot_min_to_stop(i) = q_dot_peak(i);
                    q_dot_max_to_stop(i) = 0;
                    
                    grad_q_dot_min_to_stop(i) = P.t_move;
                    grad_q_dot_max_to_stop(i) = 0;
                end
                
                % TAKE MAX/MIN OF TO PEAK AND BRAKING TRAJECTORIES
                % positions:
                if q_min_to_peak(i) <= q_min_to_stop(i)
                    q_min(i) = q_min_to_peak(i);
                    grad_q_min(i) = grad_q_min_to_peak(i);
                else
                    q_min(i) = q_min_to_stop(i);
                    grad_q_min(i) = grad_q_min_to_stop(i);
                end
                
                if q_max_to_peak(i) >= q_max_to_stop(i)
                    q_max(i) = q_max_to_peak(i);
                    grad_q_max(i) = grad_q_max_to_peak(i);
                else
                    q_max(i) = q_max_to_stop(i);
                    grad_q_max(i) = grad_q_max_to_stop(i);
                end
                
                % velocities:
                if q_dot_min_to_peak(i) <= q_dot_min_to_stop(i)
                    q_dot_min(i) = q_dot_min_to_peak(i);
                    grad_q_dot_min(i) = grad_q_dot_min_to_peak(i);
                else
                    q_dot_min(i) = q_dot_min_to_stop(i);
                    grad_q_dot_min(i) = grad_q_dot_min_to_stop(i);
                end
                
                if q_dot_max_to_peak(i) >= q_dot_max_to_stop(i)
                    q_dot_max(i) = q_dot_max_to_peak(i);
                    grad_q_dot_max(i) = grad_q_dot_max_to_peak(i);
                else
                    q_dot_max(i) = q_dot_max_to_stop(i);
                    grad_q_dot_max(i) = grad_q_dot_max_to_stop(i);
                end
                
            end
            
            % finally, make diagonal matrices out of gradients:
            grad_q_min = diag(grad_q_min);
            grad_q_max = diag(grad_q_max);
            grad_q_dot_min = diag(grad_q_dot_min);
            grad_q_dot_max = diag(grad_q_dot_max);
            
        end
    end
end