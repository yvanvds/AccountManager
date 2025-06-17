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

            if (!account.Wisa.Exists || !account.Smartschool.Exists || !account.Azure.Exists)
            {
                AddToAzure.Evaluate(account);
                AddToSmartschool.Evaluate(account);
                UnregisterSmartschool.Evaluate(account);
                DeleteFromSmartschool.Evaluate(account);
                RemoveFromAzure.Evaluate(account);

                account.OK = false;
            }
            else
            {
                ModifyAzureStudentEmail.Evaluate(account);
                ModifyAzureSchool.Evaluate(account);
                ModifySmartschoolStudentAddress.Evaluate(account);
                ModifyAccountID.Evaluate(account);
                ModifySmartschoolStemID.Evaluate(account);
                ModifySmartschoolBirthPlace.Evaluate(account);
                MoveToSmartschoolClassGroup.Evaluate(account);
                ModifySmartschoolStudentEmail.Evaluate(account);
            }
        }
    }
}
