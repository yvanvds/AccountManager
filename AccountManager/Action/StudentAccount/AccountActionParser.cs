using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    public static class AccountActionParser
    {
        public static void AddActions(State.Linked.LinkedAccount account)
        {
            if (account is null)
            {
                return;
            }

            account.OK = true;
            account.SetBasicFlags();

            if (!account.Wisa.Exists || !account.Directory.Exists || !account.Smartschool.Exists)
            {
                RemoveFromGoogle.Evaluate(account);
                RemoveFromDirectory.Evaluate(account);
                UnregisterSmartschool.Evaluate(account);
                DeleteFromSmartschool.Evaluate(account);
                AddToDirectoryAndSmartschool.Evaluate(account);
                AddToDirectory.Evaluate(account);
                RemoveFromDirectoryAndSmartschool.Evaluate(account);
                account.OK = false;
            }
            else
            {
                ModifySmartschoolStudentAddress.Evaluate(account);
                AddToADStudentGroup.Evaluate(account);
                //ModifyStudentHomeDir.Evaluate(account);
                ModifyAccountID.Evaluate(account);
                ModifySmartschoolStemID.Evaluate(account);
                //CreateHomeDir.Evaluate(account);
                MoveDirectoryClassGroup.Evaluate(account);
                MoveToSmartschoolClassGroup.Evaluate(account);
                ModifyDirectoryData.Evaluate(account);
                PrincipalNameMustEqualMail.Evaluate(account);
                AddToADClassGroup.Evaluate(account);
            }
        }
    }
}
