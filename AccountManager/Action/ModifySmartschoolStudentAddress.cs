using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class ModifySmartschoolStudentAddress : AccountAction
    {
        public ModifySmartschoolStudentAddress() : base (AccountActionType.ModifySmartschoolAddress,
            "Wijzig adres in smartschool",
            "Het adres in Wisa is verschillend van dat in smartschool", true)
        { 

        }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            linkedAccount.smartschoolAccount.City = linkedAccount.wisaAccount.City;
            linkedAccount.smartschoolAccount.Street = linkedAccount.wisaAccount.Street;
            linkedAccount.smartschoolAccount.PostalCode = linkedAccount.wisaAccount.PostalCode;
            linkedAccount.smartschoolAccount.HouseNumber = linkedAccount.wisaAccount.HouseNumber;
            linkedAccount.smartschoolAccount.HouseNumberAdd = linkedAccount.wisaAccount.HouseNumberAdd;

            await AccountApi.Smartschool.AccountManager.Save(linkedAccount.smartschoolAccount, "");
        }

        public static void ApplyIfNeeded(LinkedAccount account)
        {
            if (!checkUserHomeAddress(account))
            {
                account.SmartschoolStatusIcon = "AlertCircleOutline";
                account.SmartschoolStatusColor = "Orange";
                account.Actions.Add(new ModifySmartschoolStudentAddress());
                account.AccountOK = false;
            }
        }

        private static bool checkUserHomeAddress(LinkedAccount account)
        {
            if (account.wisaAccount.City != account.smartschoolAccount.City) return false;
            if (account.wisaAccount.Street != account.smartschoolAccount.Street) return false;
            if (account.wisaAccount.PostalCode != account.smartschoolAccount.PostalCode) return false;
            if (account.wisaAccount.HouseNumber != account.smartschoolAccount.HouseNumber) return false;
            if (account.wisaAccount.HouseNumberAdd != account.smartschoolAccount.HouseNumberAdd) return false;
            return true;
        }
    }
}
