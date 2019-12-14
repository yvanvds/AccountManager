﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    public static class StaffMemberActionParser
    {
        public static void AddActions(State.Linked.LinkedStaffMember account)
        {
            if (account is null)
            {
                return;
            }

            account.OK = true;
            account.SetBasicFlags();

            if (!account.Wisa.Exists || !account.Directory.Exists || !account.Smartschool.Exists || !account.Google.Exists)
            {
                RemoveFromGoogle.Evaluate(account);
                RemoveFromDirectory.Evaluate(account);
                DontImportFromAD.Evaluate(account);
                DontImportFromWisa.Evaluate(account);
                account.OK = false;
            } else
            {
                UpdateWisaName.Evaluate(account);
                AddToADStaffGroup.Evaluate(account);
            }
        }
    }
}