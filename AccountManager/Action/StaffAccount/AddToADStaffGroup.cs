﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    class AddToADStaffGroup : AccountAction
    {
        public AddToADStaffGroup() : base(
            "Toevoegen aan leraren groep",
            "Wanneer dit account geen lid is van deze group, is de toegang van het account beperkt.",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            bool connected = await State.App.Instance.AD.Connect().ConfigureAwait(false);
            if (!connected) return;

            // TODO: should not be bound to school
            if (account.Directory.Account.Role == AccountApi.AccountRole.Teacher)
            {
                await account.Directory.Account.AddToGroup("CN=" + State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren,OU=ArcadiaGroups,DC=arcadiascholen,DC=be").ConfigureAwait(false);
            }
            if (account.Directory.Account.Role == AccountApi.AccountRole.Support)
            {
                await account.Directory.Account.AddToGroup("CN=" + State.App.Instance.Settings.SchoolPrefix.Value + "-Secretariaat,OU=ArcadiaGroups,DC=arcadiascholen,DC=be").ConfigureAwait(false);
            }
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (account.Directory.Account.Role == AccountApi.AccountRole.Teacher 
                && !account.Directory.Account.Groups.Contains("CN=" + State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren,OU=ArcadiaGroups,DC=arcadiascholen,DC=be"))
            {
                account.Directory.FlagWarning();
                account.Actions.Add(new AddToADStaffGroup());
                account.OK = false;
            }

            if (account.Directory.Account.Role == AccountApi.AccountRole.Support
                && !account.Directory.Account.Groups.Contains("CN=" + State.App.Instance.Settings.SchoolPrefix.Value + "-Secretariaat,OU=ArcadiaGroups,DC=arcadiascholen,DC=be"))
            {
                account.Directory.FlagWarning();
                account.Actions.Add(new AddToADStaffGroup());
                account.OK = false;
            }

            //if (!account.Directory.Account.Groups.Contains("CN=" + State.App.Instance.Settings.SchoolPrefix.Value + "-Secretariaat,OU=ArcadiaGroups,DC=arcadiascholen,DC=be"))
            //{
            //    account.Directory.FlagWarning();
            //    account.Actions.Add(new AddToADStaffGroup());
            //    account.OK = false;
            //}
        }
    }
}
