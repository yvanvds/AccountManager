using System;
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

            if (!account.Wisa.Exists || !account.Directory.Exists || !account.Smartschool.Exists)
            {
                
                AddToDirectory.Evaluate(account);
                RemoveFromDirectory.Evaluate(account);
                RemoveFromSmartschool.Evaluate(account);
                DontImportFromAD.Evaluate(account);
                DontImportFromWisa.Evaluate(account);
                account.OK = false;
            }
            //if (account.Google.Exists)
            //{
            //    RemoveFromGoogle.Evaluate(account);
            //} 
            
            if (account.OK)
            {
                UpdateWisaName.Evaluate(account);
                AddToADStaffGroup.Evaluate(account);
                PrincipalNameMustEqualMail.Evaluate(account);
                ModifySmartschoolStaffEmail.Evaluate(account);
            }
        }
    }
}
